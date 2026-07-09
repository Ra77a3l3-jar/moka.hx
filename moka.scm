(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/misc.scm")

(provide moka-segment
         moka-section
         moka-configure!
         moka-enable!
         moka-disable!)

(struct MokaSegment (content))
(struct MokaSection (align segments))

(define (moka-segment content)
  (MokaSegment content))

(define (moka-section segments #:align [align 'left])
  (MokaSection align segments))

(define *moka-row-offset* 2)
(define *moka-transparent?* #t)
(define *moka-sections* '())
(define *moka-enabled?* #f)

(define (moka-configure! #:row-offset [row-offset 2] #:transparent? [transparent? #t] #:sections [sections '()])
  (set! *moka-row-offset* row-offset)
  (set! *moka-transparent?* transparent?)
  (set! *moka-sections* sections))

(define (moka-base-style)
  (if *moka-transparent?* (theme-scope-ref "ui.background") (theme-scope-ref "ui.statusline")))

(define (moka-render-bar state rect frame)
  (define width (area-width rect))
  (define height (area-height rect))
  (define y (- height *moka-row-offset*))
  (buffer/clear-with frame (area 0 y width 1) (moka-base-style)))

(define (moka-cursor-handler state rect) #f)

(define (moka-blank-native-statusline!)
  (statusline #:left '() #:center '() #:right '()))

(define (moka-restore-native-statusline!)
  (statusline))

(define (moka-enable!)
  (unless *moka-enabled?*
    (moka-blank-native-statusline!)
    (push-component!
     (new-component! "moka" #f moka-render-bar (hash "cursor" moka-cursor-handler)))
    (set! *moka-enabled?* #t)))

(define (moka-disable!)
  (when *moka-enabled?*
    (pop-last-component-by-name! "moka")
    (moka-restore-native-statusline!)
    (set! *moka-enabled?* #f)))
