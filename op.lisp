(defpackage :serapeum/op
  (:use :cl :alexandria :serapeum)
  (:import-from :trivia :match)
  #+sb-package-locks (:implement :serapeum :serapeum/op))
(in-package :serapeum/op)

(define-symbol-macro underscore '_)
(define-symbol-macro rest-arg '_*)

(defclass op-env ()
  ((body :type list :initarg :body :initarg :body)
   (vars :type list :initform nil :initarg :vars)
   (rest-op? :type boolean :initform nil :initarg :rest-op?)))

(defun make-op-env (&rest args &key &allow-other-keys)
  (apply #'make-instance 'op-env args))

(defmethod op-env-lambda ((op-env op-env))
  (with-slots (body vars rest-op?) op-env
    (let ((rest (and rest-op? `(&rest ,rest-arg))))
      `(lambda (,@(reverse vars) ,@rest)
         (declare (ignorable ,@vars))
         ,body))))

(defun var-lexical? (x env)
  (declare (ignorable x env))
  #+sbcl (sb-walker:var-lexical-p x env)
  #-sbcl nil)

(defun free? (x env) (not (var-lexical? x env)))

(defun rest-placeholder? (x env)
  (declare (ignorable env))
  (and (symbolp x)
       (free? x env)
       (string= x "_*")))

(defun placeholder? (x env)
  (declare (ignorable env))
  (and (symbolp x)
       (free? x env)
       (string= x "_")))

(defun numbered-placeholder? (x env)
  (declare (ignorable env))
  (and (symbolp x)
       (free? x env)
       (let ((x (string x)))
         #+sbcl (declare (notinline every))
         (and (>= (length x) 2)
              (string= '_ x :end2 1)
              (every #'digit-char-p (subseq x 1))))))

(defun quotation? (x env)
  (match (expand-macro-recursively x env)
    ((list 'quote _) t)
    ((list 'function _) t)
    (otherwise nil)))

(defun op? (form)
  (match form
    ((list* 'op _) t)))

(defun warn-nested-op ()
  (warn "The ~s macro cannot be nested." 'op))

(defun rest-op? (x env)
  (declare (optimize (debug 0)))

  #+sbcl
  (block nil
    (sb-walker:walk-form
     x env
     (lambda (f c e)
       (cond ((and (eql c :eval) (rest-placeholder? f e))
              (return f))
             (t f))))
    nil)

  #-sbcl
  (cond ((rest-placeholder? x env) x)
        ((listp x)
         (some (lambda (x)
                 (rest-op? x env))
               x))
        (t nil)))

(defun extract-op-env (body env)
  (let ((rest-op? (rest-op? `(progn ,@body) env)))
    (multiple-value-bind (body vars) (body+vars body env)
      (make-op-env :body body
                   :rest-op? rest-op?
                   :vars vars))))

(defun body+vars (body env)
  (let ((counter 0)
        (vars '()))
    (labels ((make-var ()
               (let ((var (intern (format nil "_~d" (incf counter)))))
                 (push var vars)
                 var))
             (make-var/numbered (x)
               (let ((n (parse-integer (subseq (string x) 1))))
                 (when (> n counter)
                   (loop repeat (- n counter) do (make-var))))
               x)
             (splice (y env)
               (mapcar (lambda (x)
                         (if (rest-placeholder? x env)
                             `(values-list ,x)
                             `(values ,x)))
                       y))
             (make-spliced-call (f env)
               (match f
                 ((list* 'progn body)
                  (make-spliced-call
                   `((lambda (&rest xs)
                       xs)
                     ,@body)
                   env))
                 ((list* fn _)
                  (let ((splice (splice (cdr f) env)))
                    `(multiple-value-call (function ,fn)
                       ,@splice)))))
             (walk-op (x env)
               (declare (ignorable env))
               #+sbcl
               (sb-walker:walk-form
                x env
                (lambda (f c e)
                  (cond ((not (eql c :eval)) f)
                        ((placeholder? f e)
                         (values (make-var) t))
                        ((numbered-placeholder? f e)
                         (values (make-var/numbered f) t))
                        ((op? f)
                         (warn-nested-op)
                         (values f t))
                        ((and (listp f)
                              (some (lambda (x) (rest-placeholder? x e)) f))
                         (let ((f (cons (car f)
                                        (mapcar (lambda (x) (walk-op x e))
                                                (cdr f)))))
                           (values
                            (make-spliced-call f e)
                            t)))
                        (t f))))
               #-sbcl
               (cond ((quotation? x env) x)
                     ((placeholder? x env) (make-var))
                     ((numbered-placeholder? x env)
                      (make-var/numbered x))
                     ((op? x)
                      (warn-nested-op)
                      x)
                     ((listp x)
                      (let ((splice? (some (rcurry #'rest-placeholder? env) x))
                            (y (mapcar (rcurry #'walk-op env) x)))
                        (if splice?
                            (make-spliced-call y env)
                            y)))
                     (t x))))
      (let ((body (walk-op `(progn ,@body) env)))
        (values body vars)))))

;; TODO Handle dotted lists.
(defmacro op (&body body &environment env)
  "GOO's simple macro for positional lambdas.

An OP is like a lambda without an argument list. Within the body of the OP
form, an underscore introduces a new argument.

     (reduce (op (set-intersection _ _ :test #'equal))
             sets)

You can refer back to each argument by number, starting with _1.

     (funcall (op (+ _ _1)) 2) => 4

You can also use positional arguments directly:

     (reduce (op (funcall _2 _1)) ...)

Argument lists can be sparse:

     (apply (op (+ _1 _3 _5)) '(1 2 3 4 5)) => 9

Note that OP with a single argument is equivalent to CONSTANTLY:

     (funcall (op 1)) => 1

and that OP with a single placeholder is equivalent to IDENTITY:

     (funcall (op _) 1) => 1

OP can also be used to define variadic functions by using _* as the
placeholder. It is not necessary to use APPLY.

     (apply (op (+ _*)) '(1 2 3 4)) => 10

Note that OP is intended for simple functions. In particular nested
uses of OP are not supported."
  (op-env-lambda (extract-op-env body env)))

;;; `op/no-walker' is not actually meant to be used. It is a reference
;;; for how `op' would work in an ideal world ("ideal world" = "world
;;; with a portable code walker").
(defmacro op/no-walker (&body body)
  (with-unique-names (counter args vec next-arg len arg-ref)
    `(let ((,counter -1)
           (,len 0))
       (declare (ignorable ,counter))
       (lambda (&rest ,args)
         (let ((,vec (coerce ,args '(simple-array * (*)))))
           (declare (ignorable ,vec))
           (flet ((,next-arg ()
                    (prog1 (svref ,vec (incf ,counter))
                      (maxf ,len (1+ ,counter))))
                  (,arg-ref (i)
                    (maxf ,len (1+ i))
                    (svref ,vec i)))
             (symbol-macrolet ((,underscore (,next-arg))
                               (,rest-arg
                                 (prog1 (nthcdr ,args (1+ ,counter))
                                   (setf ,len (length ,vec))))
                               ,@(loop for i from 0 below 50
                                       for sym = (intern (format nil "_~a" (1+ i)))
                                       collect `(,sym (arg-ref ,i))))
               (multiple-value-prog1 (progn ,@body)
                 (when (< ,len (length ,vec))
                   (error "Too many arguments."))))))))))
