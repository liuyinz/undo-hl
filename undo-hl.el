;;; undo-hl.el --- Highlight undo/redo  -*- lexical-binding: t; -*-

;; Author: Yuan Fu <casouri@gmail.com>
;; URL: https://github.com/casouri/undo-hl
;; Version: 1.0
;; Keywords: convenience
;; Package-Requires: ((emacs "26.0"))

;;; This file is NOT part of GNU Emacs

;;; Commentary:
;;
;; Sometimes in a long undo chain where Emacs jumps to a position, I
;; can’t tell whether the undo operation just moved to this position
;; or it has also deleted some text.  This package is meant to
;; alleviate that confusion: it flashes the to-be-deleted text before
;; deleting so I know what is happening.
;;
;; This package is pretty efficient, I can hold down undo button and
;; the highlight doesn’t slow down the operation.
;;

;;; Code:
;;
;; I tried to use pulse.el but it wasn’t fast enough (eg, when holding
;; down C-.), so I used a more economical implementation. Instead of a
;; flash, the highlight will persist until the next command.
;;
;; Some package, like aggressive-indent, modifies the buffer when the
;; user makes modifications (in ‘post-command-hook’, timer, etc).
;; Their modification invokes ‘before-change-functions’ just like a
;; user modification. Naturally we don’t want to highlight those
;; automatic modifications made not by the user. How do we do that?
;; Essentially we generate a ticket for each command loop
;; (‘undo-hl--hook-can-run’). One user modification = one command loop
;; = one ticket = one highlight. Whoever runs first gets to use that
;; ticket, and all other subsequent invocation of
;; `undo-hl--before-change’ must not do anything. We only constraint
;; the before hooks, ie, deletion highlight because deletion highlight
;; is blocking, while insertion highlight is not. Consecutive
;; insertion highlight only shows the last one, but consecutive
;; deletion highlight will show every highlight for
;; ‘undo-hl-flash-duration’ and can be very annoying.

(defgroup undo-hl nil
  "Custom group for undo-hl."
  :group 'undo)

(defface undo-hl-delete '((t . (:inherit diff-refine-removed)))
  "Face used for highlighting the deleted text.")

(defface undo-hl-insert '((t . (:inherit diff-refine-added)))
  "Face used for highlighting the inserted text.")

(defcustom undo-hl-undo-commands '(undo undo-only undo-redo undo-fu-only-undo undo-fu-only-redo evil-undo evil-redo)
  "Commands in this list are considered undo commands.
Undo-hl only run before and after undo commands."
  :type '(list function))

(defcustom undo-hl-flash-duration 0.02
  "Undo-hl flashes the to-be-deleted text for this number of seconds.
Note that insertion highlight is not affected by this option."
  :type 'number)

(defcustom undo-hl-edit-size-limit '(2 . 1000)
  "Cons of (MIN . MAX) limit of modifications size.
When size change is smaller or lager than limits, the highlight is ignored.
This is a useful heuristic that avoids small text property
changes that often obstruct the real edit.  Keep it at least 2."
  ;; How does text property change obstruct highlighting the real
  ;; edit: First, we only highlight one change every command loop;
  ;; second, a single undo could make multiple changes, including
  ;; moving point, changing text property, inserting/deleting text.
  ;; Both text prop change and ins/del invokes
  ;; ‘after/before-change-functions’, so if there is a text prop edit
  ;; before the real text edit in the undo history, undo-hl will
  ;; highlight the text prop change (often of size 1 at EOL) and
  ;; ignore the following text change. A simple check of size
  ;; eliminates most of such problems caused by both jit-lock and
  ;; ws-bulter.
  :type '(cons integer integer))

(defvar-local undo-hl--overlay nil
  "The overlay used for highlighting inserted region.")

(defvar-local undo-hl--hook-can-run nil
  "If non-nil, next after change hook can run.")

(defun undo-hl--edit-size-satisfied (size)
  "Return t if modification SIZE satisfys the limits."
  (<= (car undo-hl-edit-size-limit)
      size
      (cdr undo-hl-edit-size-limit)))

(defun undo-hl--overlay-pulse (beg end face)
  "Pulse highlight with region of (BEG . END) with FACE.
Duration controlled by `undo-hl-flash-duration'."
  ;; Prevent subsequent change hooks activated in this command loop
  ;; from running.
  (setq undo-hl--hook-can-run nil)
  (if undo-hl--overlay
      (move-overlay undo-hl--overlay beg end)
    (setq undo-hl--overlay (make-overlay beg end)))
  (overlay-put undo-hl--overlay 'face face)
  (sit-for undo-hl-flash-duration)
  (delete-overlay undo-hl--overlay))

(defun undo-hl--after-change (beg end len)
  "Highlight the inserted region after an undo.
This is to be called from ‘after-change-functions’, see its doc
for BEG, END and LEN."
  (when (and (memq this-command undo-hl-undo-commands)
             (eq len 0)
             (undo-hl--edit-size-satisfied (- end beg)))
    (undo-hl--overlay-pulse beg end 'undo-hl-insert)))

(defun undo-hl--before-change (beg end)
  "Highlight the to-be-deleted region before an undo.
This is to be called from ‘before-change-functions’, see its doc
for BEG and END."
  (when (and (memq this-command undo-hl-undo-commands)
             undo-hl--hook-can-run
             (not (eq beg end))
             (undo-hl--edit-size-satisfied (- end beg)))
    (undo-hl--overlay-pulse beg end 'undo-hl-delete)))

(defun undo-hl--cleanup-and-restart ()
  "Clean up highlight and allow change hooks to run."
  (if (memq this-command undo-hl-undo-commands)
      (setq undo-hl--hook-can-run t)
    (when undo-hl--overlay
      (delete-overlay undo-hl--overlay)
      (setq undo-hl--overlay nil))))

;;;###autoload
(define-minor-mode undo-hl-mode
  "Highlight text changes caused by undo related commands.
Note that this is a local minor mode recommended only for text-editing modes."
  :lighter " UH"
  :group 'undo
  (if undo-hl-mode
      (progn
        (add-hook 'before-change-functions #'undo-hl--before-change -50 t)
        (add-hook 'after-change-functions #'undo-hl--after-change -50 t)
        (add-hook 'pre-command-hook #'undo-hl--cleanup-and-restart 0 t))
    (remove-hook 'before-change-functions #'undo-hl--before-change t)
    (remove-hook 'after-change-functions #'undo-hl--after-change t)
    (remove-hook 'pre-command-hook #'undo-hl--cleanup-and-restart t)))

(provide 'undo-hl)

;;; undo-hl.el ends here
