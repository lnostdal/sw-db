;;;; http://nostdal.org/ ;;;;


(defsystem sw-db
  :depends-on (:sw-mvc
               :postmodern)

  :serial t
  :components
  ((:module src
    :serial t
    :components
    ((:file "package")
     (:file "read-macros")
     (:file "common")
     (:file "model-container")
     (:file "model-container-table")
     (:file "meta-class")
     #|(:file "operation-save")|#
     #|(:file "model-container-query")|#
     ))))