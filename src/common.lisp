;;;; http://nostdal.org/ ;;;;

(in-package sw-db)
(in-readtable sw-db)


;; TODO: No, this is no good. It should be a container type thing; it should be a request vs. a or its container.
(defun exists-in-db-p (obj)
  (slot-boundp obj 'id))


;; Our (SETF SVUC) method for DB-CLASS depends on this.
(define-variable *touched-db-objects*)

(sw-stm::add-dynamic-binding '*touched-db-objects* λλnil)

#| The function name here might be a bit misleading; this is not actually executed at STM commit time; but just
before STM commit begins. |#
(defun commit-db-objects ()
  (dolist (db-object (copy-seq *touched-db-objects*))
    (if (or (plusp (reference-count-of db-object))
            (not (gc-p-of db-object)))
        (put-db-object db-object)
        (when (and (gc-p-of db-object)
                   (exists-in-db-p db-object))
          (remove db-object (container-of db-object))))))


(sw-stm::add-after-fn (lambda () (commit-db-objects)))

#|(sw-stm::add-dynamic-binding 'postmodern:*database*
                             λλ(if postmodern:*database*
                                   postmodern:*database*
                                   (apply #'postmodern:connect *database-connection-info*)))|#
;; TODO: UNWIND-PROTECT missing here!
#|(sw-stm::add-after-fn λλ(postmodern:disconnect postmodern:*database*))|#


(define-variable *database-connection-info*
    :value '("temp" "temp" "temp" "localhost" :pooled-p t)
    :doc "SW-DB> (describe 'postmodern:connect)
  Lambda-list: (DATABASE USER PASSWORD HOST &KEY (PORT 5432) POOLED-P (USE-SSL *DEFAULT-USE-SSL*))")


(defmacro with-db-connection (&body body)
  "Ensure that we're connected to the DB. Note that this will not reconnect if we're already connected. This holds
even if *DATABASE-CONNECTION-INFO* changes."
  `(flet ((body-fn () ,@body))
     (if postmodern:*database*
         (body-fn)
         (with-connection *database-connection-info*
           (body-fn)))))


(defun get-db-object (id type &key (cache-p t))
  "Returns (values NIL NIL) when no object with given ID and TYPE was found.
Returns (values object :FROM-CACHE) when object was found in cache.
Returns (values object :FROM-DB) when object had to be fetched from the database.
If CACHE-P is T (default) the object will be placed in a Lisp-side cache for
fast (hash-table) retrieval later."
  (declare (integer id)
           (symbol type))
  (with-locked-object (find-class type)
    (when cache-p
      (multiple-value-bind (dao found-p) (get-object id type)
        (when found-p
          (return-from get-db-object (values dao :from-cache)))))
    (if-let (dao (with-db-connection (get-dao type id)))
      (progn
        (when cache-p
          (cache-object dao))
        (values dao :from-db))
      (values nil nil))))


(defun put-db-object (dao &key (cache-p t))
  "NOTE: Users are not meant to use this directly; use SW-MVC:INSERT instead."
  (declare (type db-object dao))
  #| NOTE: Not using DB transactions here since SW-STM does it for us already. By the time we get to the commit-bit,
  any concurrency related issues have been resolved. |#
  (id-of dao) ;; Postmodern depends on this slot being bound; it'll check using SLOT-BOUNDP.
  #| TODO: We touch all slots (STM) here. This is needed because the commit below calls UPDATE-DAO which will also
  touch all slots. Get rid of this, as especially wrt. MVC (dataflow) it'll cause extra overhead. |#
  (sw-stm:touch dao)
  #| TODO: It'd be great if we could group commits like these together and place them within the scope of a single
  WITH-DB-CONNECTION form. Though, we might not save a _lot_ by doing this since Postmodern pools connections for
  us. |#
  (sw-stm:when-commit ()
    (with-locked-object (class-of dao) ;; vs. GET-DB-OBJECT.
      (with-db-connection (save-dao dao))
      (when cache-p
        (cache-object dao)))))


(defun remove-db-object (dao)
  "NOTE: Users are not meant to use this directly; use SW-MVC:REMOVE instead."
  (declare (type db-object dao))
  ;; TODO: See the TODOs in PUT-DB-OBJECT.
  (sw-stm:touch dao)
  (deletef *touched-db-objects* dao)
  (sw-stm:when-commit ()
    (with-locked-object (class-of dao) ;; vs. GET-DB-OBJECT.
      (with-db-connection
        (dolist (dao (mklst dao))
          (delete-dao dao)))
      #| NOTE: I'm not doing this explicitly because it might still be interesting to get hold of an object based
      on only knowing its ID, and even though it is deleted it might still have hard links (GC) multiple places in
      the code. |#
      #|(uncache-object dao)|#)))


(defun dao-table-info (dao-class)
  "Returns a list of alists containing information about the columns of the DB
table currently representing DAO-CLASS."
  (declare ((or class symbol) dao-class))
  (let ((table-name (s-sql:to-sql-name (dao-table-name dao-class))))
    (with-db-connection
      (query (:select (:as 'pg_attribute.attname 'name)
                      (:as 'pg_type.typname 'type)
                      :from 'pg_attribute
                      :inner-join 'pg_type :on (:= 'pg_type.oid 'pg_attribute.atttypid)
                      :where (:and (:= 'attrelid
                                       (:select 'oid :from 'pg_class :where (:= 'relname table-name)))
                                   (:> 'attnum 0)))
             :alists))))
