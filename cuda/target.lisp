;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2010 by Alexander Gavrilov.
;;;
;;; See LICENCE for details.
;;;
;;; This file defines the CUDA code generation target,
;;; including the relevant layer, C types and builtins.
;;;

(in-package :cl-gpu)

;;; Target definition

(deflayer cuda-target (gpu-target))

(def reserved-c-names
    "__device__" "__constant__" "__shared__" "__global__")

(def macro with-cuda-target (&body code)
  `(with-active-layers (cuda-target) ,@code))

(def method call-with-target ((target (eql :cuda)) thunk)
  (with-cuda-target (funcall thunk)))

(def function lookup-cuda-module (module-id)
  (let* ((context (or (cuda-current-context)
                      (error "No CUDA context is active.")))
         (instance (gethash-with-init module-id (cuda-context-module-hash context)
                                      (with-cuda-target
                                        (load-gpu-module-instance module-id)))))
    (unless (car (gpu-module-instance-change-sentinel instance))
      (with-cuda-target
        (upgrade-gpu-module-instance module-id instance)))
    instance))

(def method target-module-lookup-fun ((target (eql :cuda)))
  #'lookup-cuda-module)

(setf *current-gpu-target* :cuda)

;;; Toplevel object code generation

(def layered-method generate-c-code :in cuda-target ((obj gpu-global-var))
  (format nil "~A ~A"
          (if (or (constant-var? obj) (dynarray-var? obj))
              "__constant__"
              "__device__")
          (call-next-method)))

(def layered-method generate-c-code :in cuda-target ((obj gpu-function))
  (format nil "extern \"C\" ~A ~A"
          (if (typep obj 'gpu-kernel)
              "__global__"
              "__device__")
          (call-next-method)))

(def layered-method generate-c-code :in cuda-target ((obj gpu-shared-var))
  (concatenate 'string "__shared__ " (call-next-method)))

(def layered-method generate-c-code :in cuda-target ((obj gpu-module))
  (if (error-table-of obj)
      (format nil "__constant__ struct { unsigned group; unsigned *buffer; } GPU_ERR_BUF;~%~%~A"
              (call-next-method))
      (call-next-method)))

;;; C types

(def layered-method c-type-string :in cuda-target (type)
  (case type
    (:int64 "long long")
    (:uint64 "unsigned long long")
    (otherwise (call-next-method))))

(def layered-method c-type-string :in cuda-target ((type cons))
  (case (first type)
    (:tuple (let ((size (second type))
                  (base (third type)))
              (unless (and (> size 0)
                           (<= size (case base
                                      ((:double :int64) 2)
                                      (t 4))))
                (error "Invalid size ~A for tuple of ~A" size base))
              (format nil "~A~A"
                      (case base
                        (:int8 "char") (:uint8 "uchar")
                        (:int16 "short") (:uint16 "ushort")
                        (:int32 "int") (:uint32 "uint")
                        (:int64 "longlong")
                        (:float "float") (:double "double")
                        (t (error "Invalid tuple type ~A" base)))
                      size)))
    (otherwise (call-next-method))))

(def layered-method c-type-size :in cuda-target (type)
  (case type
    (:pointer +cuda-ptr-size+)
    (otherwise (call-next-method))))

(def layered-method c-type-alignment :in cuda-target (type)
  (case type
    (:pointer +cuda-ptr-size+)
    (otherwise (call-next-method))))

;;; Abort command

(def function transform-abort-args (args)
  (let ((idx 0)
        (size 0)
        (types nil)
        (vals nil))
    (labels ((add-item (type value)
               (let* ((tsize (foreign-type-size type))
                      (tcount (floor (+ tsize 3) 4)))
                 (prog1
                     `(elt error-data ,idx)
                   (push type types)
                   (push (list size type value) vals)
                   (incf idx)
                   (incf size tcount))))
             (handle (arg)
               (cond ((typep arg 'walked-form)
                      (add-item (form-c-type-of arg) arg))
                     ((and (consp arg)
                           (keywordp (first arg)))
                      (add-item (first arg) (second arg)))
                     ((and (consp arg)
                           (eq (first arg) 'list))
                      `(list ,@(mapcar #'handle (rest arg))))
                     ((and (consp arg)
                           (eq (first arg) 'quote))
                      arg)
                     (t
                      `(quote ,arg)))))
      (let ((exprs (mapcar #'handle args)))
        (values size (nreverse types) exprs (nreverse vals))))))

(def layered-method emit-abort-command :in cuda-target (stream exception args)
  (with-c-code-emitter-lexicals (stream)
    (if (is-optimize-level? 'debug 1)
        (bind (((:values size types exprs vals) (transform-abort-args args))
               (full-size (+ size 2))
               (entry (list types `(error ',exception ,@exprs)))
               (etable (error-table-of *cur-gpu-module*))
               (err-id
                (aif (rassoc entry etable :test #'equal)
                     (first it)
                     (aprog1 (1+ (reduce #'max etable :key #'first :initial-value 0))
                       (push (list* it entry) (error-table-of *cur-gpu-module*))))))
          (assert (< full-size 256))
          (with-c-code-block (stream)
            (code "if (GPU_ERR_BUF.buffer) ")
            (with-c-code-block (stream)
              (emit "unsigned EPOS = atomicAdd(GPU_ERR_BUF.buffer,~A)+1;" (1+ full-size))
              (code #\Newline
                    "if (EPOS<" (- +cuda-error-buf-size+ full-size) ") ")
              (with-c-code-block (stream)
                (code "GPU_ERR_BUF.buffer[EPOS+1]=GPU_ERR_BUF.group+" full-size ";" #\Newline)
                (code "GPU_ERR_BUF.buffer[EPOS+2]=" err-id ";" #\Newline)
                (dolist (item vals)
                  (code "*(" (c-type-string (second item)) "*)(GPU_ERR_BUF.buffer+EPOS+"
                        (+ 3 (first item)) ")=" (third item) ";" #\Newline))
                (code "GPU_ERR_BUF.buffer[EPOS]=" +cuda-error-magic+ ";" #\Newline
                      "__threadfence();")))
            (code #\Newline "__trap();"))
          (code #\Newline))
        (code "__trap();" #\Newline))))

;;; Built-in functions

;; Tuples

(def (c-code-emitter :in cuda-target) tuple (&rest args)
  (emit "make_~A" (c-type-string (form-c-type-of -form-)))
  (emit-separated -stream- args ","))

(def (c-code-emitter :in cuda-target) untuple (tuple)
  (if (has-merged-assignment? -form-)
      (with-c-code-block (-stream-)
        (let ((tuple/type (form-c-type-of tuple)))
          (code (c-type-string tuple/type) " TMP = " tuple ";" #\Newline)
          (loop for i from 0 below (second tuple/type)
             and name in '("x" "y" "z" "w")
             when (emit-merged-assignment -stream- -form- i
                                          (format nil "TMP.~A" name))
             do (code ";"))))
      (code tuple ".x")))

;; Dimensions

(macrolet ((dimfun (name stem)
             `(progn
                (def (type-computer :in cuda-target) ,name (&optional dimension)
                  (if dimension
                      (let ((idx (ensure-int-constant dimension)))
                        (unless (and (>= idx 0) (<= idx 3))
                          (error "Invalid grid dimension index ~A in call to ~A" idx ',name))
                        :uint32)
                      `(:tuple :uint32 3)))
                (def (c-code-emitter :in cuda-target) ,name (&optional dimension)
                  (if dimension
                      (code ,stem "." (aref #("x" "y" "z") (ensure-int-constant dimension)))
                      (code ,stem))))))
  (dimfun thread-index "threadIdx")
  (dimfun thread-count "blockDim")
  (dimfun block-index "blockIdx")
  (dimfun block-count "gridDim"))

;; Synchronization

(def (c-code-emitter :in cuda-target) barrier (&optional mode)
  (code (acase (unwrap-keyword-const mode)
          ((nil :block) "__syncthreads()")
          ((:block-fence) "__threadfence_block()")
          ((:grid-fence) "__threadfence()")
          ((:system-fence) "__threadfence_system()")
          (otherwise
           (error "Invalid CUDA barrier mode: ~S" it)))))
