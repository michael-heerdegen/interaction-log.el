;;; interaction-log.el --- exhaustive log of interactions with Emacs


;; Copyright (C) 2012-2013 Michael Heerdegen

;; Author: Michael Heerdegen <michael_heerdegen@web.de>
;; Maintainer: Michael Heerdegen <michael_heerdegen@web.de>
;; Created: Dec 29 2012
;; Keywords: convenience
;; Homepage: https://github.com/michael-heerdegen/interaction-log.el
;; Version: 1.1


;; This file is not part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.


;;; Commentary:
;;;
;;; This package provides a buffer *Emacs Log* showing the last hit
;;; keys and executed commands, messages and file loads in
;;; chronological order.  This enables you to reconstruct the last
;;; seconds of your work with Emacs.
;;;
;;; Installation: Put this file in your load path and byte-compile it.
;;; To start logging automatically at startup, add this to your init
;;; file:
;;;
;;; (require 'interaction-log)
;;; (interaction-log-mode +1)
;;;
;;; You probably will want to have a hotkey for showing the log
;;; buffer, so also add something like
;;;
;;; (global-set-key [f1] (lambda () (interactive) (display-buffer ilog-buffer-name)))
;;;
;;; Alternatively, there is a command `ilog-show-in-new-frame' that
;;; you can use to display the log buffer in a little new frame whose
;;; parameters can be controlled by customizing
;;; `ilog-new-frame-parameters'.
;;;
;;; Usage: Use `interaction-log-mode' to toggle logging.  Enabling the
;;; mode will cause all messages and all pressed keys (along with the
;;; actually executed command and the according buffer) to be logged
;;; in the background.  Also loading of files will be logged - in a
;;; tree-style manner for recursive loads.  If an executed command
;;; causes any buffer to change, it will be highlighted in orange so
;;; you can check if you made changes by accident.  If a command
;;; caused any message to be displayed in the echo area (e.g. if an
;;; error occurred), it is highlighted in red.
;;; 
;;; If you find any bugs or have suggestions for improvement, please
;;; tell me!


;;; Code:

(eval-when-compile (require 'cl))
(require 'timer)
(require 'font-lock)
(require 'easymenu)


;;; Customizable stuff

(defgroup interaction-log nil
  "Emacs Interaction Log."
  :prefix "ilog-"
  :group 'convenience)

(defface ilog-non-change-face
  '((default :weight bold)
    (((class color) (min-colors 16) (background light)) :foreground "ForestGreen")
    (((class color) (min-colors 88) (background dark))  :foreground "Green1")
    (((class color) (min-colors 16) (background dark))  :foreground "Green")
    (((class color)) :foreground "green")) ; i.e. "success" in Emacs 24
  "Face for keys that didn't cause buffer changes."
  :group 'interaction-log)

(defface ilog-change-face
  '((default :weight bold)
    (((class color) (min-colors 16)) :foreground "DarkOrange")
    (((class color)) :foreground "yellow")) ; i.e. "warning" in Emacs 24
  "Face for keys that caused buffer changes."
  :group 'interaction-log)

(defface ilog-echo-face
  '((default :weight bold)
    (((class color) (min-colors 88) (background light)) :foreground "Red1")
    (((class color) (min-colors 88) (background dark))  :foreground "Pink")
    (((class color) (min-colors 16) (background light)) :foreground "Red1")
    (((class color) (min-colors 16) (background dark))  :foreground "Pink")
    (((class color) (min-colors 8)) :foreground "red")
    (t :inverse-video t))	; i.e. "error" in Emacs 24
  "Face for keys that caused text being displayed in the echo area."
  :group 'interaction-log)

(defface ilog-buffer-face
  '((((class color) (min-colors 88) (background light)) :foreground "DarkBlue")
    (((class color) (min-colors 88) (background dark)) :foreground "Light Slate Blue")
    (t :weight bold))
  "Face for buffer names.")

(defface ilog-load-face '((t (:inherit 'font-lock-string-face)))
  "Face for lines describing file loads."
  :group 'interaction-log)

(defface ilog-message-face '((t (:inherit shadow)))
  "Face for messages."
  :group 'interaction-log)

(defcustom ilog-tail-mode t
  "When non-nil, let the cursor follow the end of the log buffer.
This is like in *Messages*: if you put the cursor at the end of
the *Emacs Log* buffer, it will stay at the buffer's end when
more stuff is added.
When nil, the cursor will stay at the same text position."
  :group 'interaction-log :type 'boolean)

(defcustom ilog-log-max t
  "Maximum number of lines to keep in the *Emacs Log* buffer.
If t, don't truncate the buffer when it becomes large.

Note: Displaying a very large log buffer may increase Emacs CPU
usage as long as the buffer is displayed.  Don't set this to t if
you plan to display the log all the time."
  :group 'interaction-log :type '(choice (const  :tag "Unlimited" t)
                                         (number :tag "lines")))

(defcustom ilog-idle-time .1
  "Refresh log every this many seconds idle time."
  :group 'interaction-log :type 'number)

(defcustom ilog-initially-show-buffers nil
  "Whether to show buffer names initially.
You can also toggle displaying buffer names in the log buffer by
typing \\<ilog-log-buffer-mode-map>\\[ilog-toggle-display-buffer-names]."
  :group 'interaction-log :type 'boolean)

(defvar ilog-log-buffer-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [?t] #'ilog-toggle-view)
    (define-key map [?b] #'ilog-toggle-display-buffer-names)
    map)
  "Keymap for `ilog-log-buffer-mode'.")

(defcustom interaction-log-mode-hook '()
  "Hook run when entering `interaction-log-mode'."
  :group 'interaction-log :type 'hook)

(defcustom ilog-log-buffer-mode-hook '()
  "Hook run when entering `ilog-log-buffer-mode'."
  :group 'interaction-log :type 'hook)

(defcustom ilog-new-frame-parameters
  '((menu-bar-lines .         0)
    (vertical-scroll-bars . nil)
    (border-width .           0)
    (left-fringe  .           0)
    (right-fringe .           1)
    (left         .      (- -17))
    (width        .          35)
    (height       .          20)
    (font         .         "8")
    (background-color . "black")
    (foreground-color . "gray90")
    (background-mode  . dark))
  "Alist of frame parameters for `ilog-show-in-new-frame'.
These parameters are applied to the new frame."
  :group 'interaction-log
  :type '(repeat (cons :format "%v"
		       (symbol :tag "Parameter")
		       (sexp :tag "Value"))))


;;; Other stuff

(easy-menu-define ilog-minor-mode-menu ilog-log-buffer-mode-map
  "Menu used when `ilog-log-buffer-mode' is active."
  '("Log"
    ["Toggle view"           ilog-toggle-view]
    ["Toggle buffer names"   ilog-toggle-display-buffer-names]))


;;; Internal Variables

(defvar ilog-recent-commands nil)

(defvar ilog-changing-log-buffer-p nil
  "Non-nil means buffer changes should not be recorded.
Bound to t  when adding to the log buffer.")

(defvar ilog-last-command-changed-buffer-p nil
  "Whether the last command caused changes to any buffer.")

(defvar ilog-buffer-name "*Emacs Log*"
  "The name used for the log buffer.")

(defvar ilog-recent-commands-messages-marker
  (with-current-buffer (get-buffer-create "*Messages*")
    (let ((marker (point-min-marker)))
      (set-marker-insertion-type marker nil)
      marker))
  "Marking how far we got with copying from *Messages*.")

(defvar ilog-truncation-timer nil)

(defvar ilog-insertion-timer nil)

(defvar ilog-temp-load-hist nil
  "Holding file loads not-yet processed.")

(defvar ilog-display-state nil)

(defvar ilog-eob-wins '())

(defvar ilog-last-inserted-command nil
  "Last inserted command, as a `ilog-log-entry' struct.
nil when the last inserted line was not a command (even if a
post-messg).")


;;; User commands

(define-minor-mode interaction-log-mode
  "Global minor mode logging keys, commands, file loads and messages.
Logged stuff goes to the *Emacs Log* buffer."
  :group 'interaction-log
  :lighter nil
  :global t
  :after-hook interaction-log-mode-hook
  (if interaction-log-mode
      (progn
        (add-hook 'after-change-functions #'ilog-note-buffer-change)
        (add-hook 'pre-command-hook       #'ilog-record-this-command)
        (add-hook 'post-command-hook      #'ilog-post-command)
        (setq ilog-truncation-timer (run-at-time 30 30 #'ilog-truncate-log-buffer))
        (setq ilog-insertion-timer (run-with-timer ilog-idle-time ilog-idle-time
						   #'ilog-timer-function))
        (message "Interaction Log: started logging in %s" ilog-buffer-name)
	(easy-menu-add ilog-minor-mode-menu))
    (remove-hook 'after-change-functions #'ilog-note-buffer-change)
    (remove-hook 'pre-command-hook       #'ilog-record-this-command)
    (remove-hook 'post-command-hook      #'ilog-post-command)
    (when (timerp ilog-truncation-timer) (cancel-timer ilog-truncation-timer))
    (setq ilog-truncation-timer nil)
    (when (timerp ilog-insertion-timer) (cancel-timer ilog-insertion-timer))
    (setq ilog-insertion-timer nil)))

(defun ilog-toggle-view ()
  "Toggle between different view states.
Toggle successively between showing only messages, only
commands, only file loads, and everything."
  (interactive)
  (ilog-log-buf-current-or-barf)
  (case ilog-display-state
    ((nil)
     (add-to-invisibility-spec 'ilog-command)
     (add-to-invisibility-spec 'ilog-buffer)
     (add-to-invisibility-spec 'ilog-load)
     (setq ilog-display-state 'messages)
     (message "Showing only messages"))
   ((messages)
    (remove-from-invisibility-spec 'ilog-command)
    (when ilog-initially-show-buffers
      (remove-from-invisibility-spec 'ilog-buffer))
    (add-to-invisibility-spec 'ilog-message)
    (setq ilog-display-state 'commands)
    (message "Showing only commands"))
   ((commands)
    (remove-from-invisibility-spec 'ilog-load)
    (add-to-invisibility-spec 'ilog-command)
    (add-to-invisibility-spec 'ilog-buffer)
    (add-to-invisibility-spec 'ilog-message)
    (setq ilog-display-state 'loads)
    (message "Showing only file loads"))
   ((loads)
    (remove-from-invisibility-spec 'ilog-load)
    (remove-from-invisibility-spec 'ilog-command)
    (when ilog-initially-show-buffers
      (remove-from-invisibility-spec 'ilog-buffer))
    (remove-from-invisibility-spec 'ilog-message)
    (setq ilog-display-state nil)
    (message "Showing everything"))))

(defun ilog-toggle-display-buffer-names ()
  "Toggle display of buffers in log buffer."
  (interactive)
  (ilog-log-buf-current-or-barf)
  (unless (memq 'ilog-command buffer-invisibility-spec)
    (if (memq 'ilog-buffer buffer-invisibility-spec)
	(remove-from-invisibility-spec 'ilog-buffer)
      (add-to-invisibility-spec 'ilog-buffer))))

(defun ilog-show-in-new-frame ()
  "Display log in a pop up frame.
Customize `ilog-new-frame-parameters' to specify parameters of
the newly created frame."
  (interactive)
  (unless interaction-log-mode (interaction-log-mode +1))
  (let ((after-make-frame-functions
	 (list (lambda (f)
		 (run-with-idle-timer
		  0 nil
		  (lambda (f)
		    (let ((win (frame-selected-window f)))
		      (push win ilog-eob-wins)
		      (set-window-dedicated-p win t)))
		  f)))))
    (display-buffer-pop-up-frame
     ilog-buffer-name
     `((pop-up-frame-parameters . ,ilog-new-frame-parameters)))))


;;; Helper funs

(defun ilog-log-buf-current-or-barf ()
  "Barf if the ilog log buffer is not current."
  (unless (eq (current-buffer) (get-buffer ilog-buffer-name))
    (error "You can use this command in %s only" ilog-buffer-name)))

(define-minor-mode ilog-log-buffer-mode
  "Minor mode for the ilog log buffer.

Key bindings:

\\{ilog-log-buffer-mode-map}"
  :keymap ilog-log-buffer-mode-map
  :after-hook ilog-log-buffer-mode-hook)

(defstruct ilog-log-entry
  keys command buffer-name (pre-messages "") (post-messages "") changed-buffer-p loads (mult 1))

(defun ilog-log-file-load (file)
  "Annotate a file load in `ilog-temp-load-hist'."
  (when ilog-recent-commands
    (callf concat (ilog-log-entry-post-messages (car ilog-recent-commands))
      (ilog-get-last-messages)
      (propertize
       (concat (if load-file-name
                   (concat (file-name-sans-extension (file-name-nondirectory load-file-name))
                           " loaded ")
                 "Loaded ")
               file)
       'load-message t)
      "\n")
    ;; ilog-temp-load-hist
    (push (cons load-file-name file) ilog-temp-load-hist)))

(defun ilog-parse-load-tree ()
  "Calculate load levels according to `ilog-temp-load-hist'.
Save the result in `ilog-temp-load-hist'."
  ;; Or is there a more efficient way to get the load recursion depth?
  (prog1  (let ((last-loaded ()) parser)
	    (setq parser (lambda (accumulated entries)
			   (if (null entries)
			       accumulated
			     (let* ((entry (car entries))
				    (loaded-directly-p (not (car entry)))
				    (loaded-by-ancestor-p (and (car entry)
							       (member (car entry) last-loaded)))
				    (last-loaded
				     (cond
				      (loaded-directly-p (list (cdr entry)))
				      (loaded-by-ancestor-p (cons (cdr entry) loaded-by-ancestor-p))
				      (t             (list* (cdr entry) (car entry) (cdr last-loaded))))))
			       (funcall parser
					(cons (1- (length last-loaded)) accumulated)
					(cdr entries))))))
	    (funcall parser () ilog-temp-load-hist))
    (setq ilog-temp-load-hist '())))

(add-hook 'after-load-functions #'ilog-log-file-load)

(defun ilog-get-last-messages ()
  "Return a string including the last messages.
This is a multiline string containing all messages that appeared
in *Messages* since the last call of this function."
  (with-current-buffer (get-buffer-create "*Messages*")
    (prog1 (if (< ilog-recent-commands-messages-marker (point-max))
               (buffer-substring ilog-recent-commands-messages-marker (point-max))
             "")
      (move-marker ilog-recent-commands-messages-marker (point-max)))))

(defun ilog-entering-password-p ()
  "Whether the user is currently entering a password."
  (and
   (boundp 'read-passwd-map)
   (keymapp read-passwd-map)
   (eq read-passwd-map (current-local-map))))

(defun ilog-record-this-command ()
  "Push info about the current command to `ilog-recent-commands'."
  (let ((keys (if (ilog-entering-password-p) [??] ;hide passwords!
		(apply #'vector
		       (mapcar
			(lambda (key) (if (consp key) ;; (mouse-... event-data)
				     (car key)
				   key))
			(this-command-keys-vector)))))
	(command (cond
		  ((ilog-entering-password-p) "(entering-password)")
		  ((not (symbolp this-command)) "(anonymous command)")
		  (t this-command)))
	(buffer-name (buffer-name))
	(pre-messages (ilog-get-last-messages))
	(last-log-entry (car ilog-recent-commands)))
    (if (and last-log-entry ;check whether we can akkumulate while recording
	     (equal keys        (ilog-log-entry-keys        last-log-entry))
	     (equal command     (ilog-log-entry-command     last-log-entry))
	     (equal buffer-name (ilog-log-entry-buffer-name last-log-entry))
	     (string= "" pre-messages)
	     (string= "" (ilog-log-entry-post-messages last-log-entry))
	     (not (ilog-log-entry-loads last-log-entry)))
	(incf (ilog-log-entry-mult last-log-entry))
      (push (make-ilog-log-entry
	     :keys keys
	     :command command
	     :buffer-name buffer-name
	     :pre-messages pre-messages)
	    ilog-recent-commands))))

(defun ilog-post-command ()
  "DTRT after a command was executed.
Goes to `post-command-hook'."
  (when ilog-recent-commands
    (callf concat (ilog-log-entry-post-messages (car ilog-recent-commands)) (ilog-get-last-messages))
    (setf (ilog-log-entry-changed-buffer-p (car ilog-recent-commands))
	  ilog-last-command-changed-buffer-p)
    (setq ilog-last-command-changed-buffer-p nil)
    ;; handle load-tree
    (setf (ilog-log-entry-loads (car ilog-recent-commands)) (ilog-parse-load-tree))))

(defun ilog-timer-function ()
  "Transform and insert pending data into the log buffer."
  (when (let ((current-idle-time (current-idle-time)))
	  (and current-idle-time (> (time-to-seconds current-idle-time) ilog-idle-time)))
    (let* ((ilog-buffer
	    (or (get-buffer ilog-buffer-name)
		(with-current-buffer (generate-new-buffer ilog-buffer-name)
		  (setq truncate-lines t
			buffer-invisibility-spec (if ilog-initially-show-buffers '() '(ilog-buffer)))
		  (set (make-local-variable 'scroll-margin) 0)
		  (set (make-local-variable 'scroll-conservatively) 10000)
		  (set (make-local-variable 'scroll-step) 1)
		  (setq buffer-read-only t)
		  (ilog-log-buffer-mode)
		  (current-buffer))))
	   ateobp (selected-win (selected-window)))
      (when ilog-tail-mode
	(setq ilog-eob-wins
	      (delq selected-win
		    (delq nil (mapcar (lambda (win) (if (window-live-p win) win nil))
				      ilog-eob-wins))))
	(when (and (eq (current-buffer) ilog-buffer) (eobp))
	  (push selected-win ilog-eob-wins)))
      (with-current-buffer ilog-buffer
	(setq ateobp (eobp))
	(let ((ilog-changing-log-buffer-p t) (deactivate-mark nil) (inhibit-read-only t) (firstp t))
	  (save-excursion
	    (goto-char (point-max))
	    (if ilog-recent-commands
		(dolist (entry (nreverse ilog-recent-commands))
		  (let ((keys        (ilog-log-entry-keys             entry))
			(command     (ilog-log-entry-command          entry))
			(buf         (ilog-log-entry-buffer-name      entry))
			(pre-mess    (ilog-log-entry-pre-messages     entry))
			(post-mess   (ilog-log-entry-post-messages    entry))
			(changedp    (ilog-log-entry-changed-buffer-p entry))
			(mult        (ilog-log-entry-mult             entry))
			(load-levels (ilog-log-entry-loads            entry)))
		    (when firstp
		      (setq firstp nil)
		      ;; check whether to combine with last inserted line
		      (when (and ilog-last-inserted-command
				 (equal keys    (ilog-log-entry-keys    ilog-last-inserted-command))
				 (equal command (ilog-log-entry-command ilog-last-inserted-command))
				 (equal buf (ilog-log-entry-buffer-name ilog-last-inserted-command))
				 (string= pre-mess "") (string= post-mess "")
				 (equal changedp (ilog-log-entry-changed-buffer-p
						  ilog-last-inserted-command))				 )
			(incf mult (ilog-log-entry-mult ilog-last-inserted-command))
			(incf (ilog-log-entry-mult entry)
			      (ilog-log-entry-mult ilog-last-inserted-command))
			;; delete last log line
			(search-backward-regexp "[^[:space:]]")
			(beginning-of-line)
			(delete-region (point) (point-max))))
		    (insert (propertize (if (looking-back "\\`\\|\n") "" "\n")
					'invisible 'ilog-command)
			    (ilog-format-messages pre-mess)
			    (propertize (concat (if (> mult 1) (format "%s*" mult) "")
						(key-description keys))
					'face (case changedp
						((t)    'ilog-change-face)
						((echo) 'ilog-echo-face)
						(t      'ilog-non-change-face))
					'invisible 'ilog-command)
			    (propertize (concat " " (format "%s" command))
					'invisible 'ilog-command)
			    (propertize (format " %s" buf)
					'face 'ilog-buffer-face
					'invisible 'ilog-buffer)
			    (when post-mess (propertize "\n" 'invisible 'ilog-command))
			    (ilog-format-messages post-mess load-levels))
		    (setq ilog-last-inserted-command (and (equal post-mess "") entry))
		    (deactivate-mark t)))
	      ;; No keys hitten.  Collect new messages
	      (let ((messages (ilog-get-last-messages)))
		(unless (string= messages "")
		  (insert (ilog-format-messages messages))
		  (setq ilog-last-inserted-command nil))))
	    (setq ilog-recent-commands ())))
	(when (buffer-modified-p) ; only do stuff triggering redisplay
				  ; when buffer was really modified
	  (set-buffer-modified-p nil)
	  (when ilog-tail-mode
	    (if ilog-eob-wins
		(dolist (win ilog-eob-wins)
		  (set-window-point win (point-max)))
	      (when ateobp (goto-char (point-max))))))))))

(defun ilog-cut-surrounding-newlines (string)
  "Cut all newlines at beginning and end of STRING.
Return the result."
  (when (string-match "\n+\\'" string)
    (setq string (substring string 0 (match-beginning 0))))
  (when (string-match "\\`\n+" string)
    (setq string (substring string (match-end 0))))
  string)

(defun ilog-format-messages (string &optional load-levels)
  "Format and propertize messages in STRING."
  (if (and (stringp string) (not (equal string "")))
      (let ((messages (ilog-cut-surrounding-newlines string)))
	(mapconcat 
	 (lambda (line)
	   (let ((load-mesg-p (when (get-text-property 0 'load-message line)
				(prog1 (car load-levels)
				  (callf cdr load-levels)))))
	     (propertize
	      (concat (if load-mesg-p (make-string load-mesg-p ?\ ) "") line "\n")
	      'face (if load-mesg-p 'ilog-load-face 'ilog-message-face)
	      'invisible (if load-mesg-p 'ilog-load 'ilog-message))))
	 (split-string messages "\n") ""))
    ""))

(defun ilog-note-buffer-change (&rest _)
  "Remember that this command changed any buffer.
Also remember whether this command caused any output in the Echo
Area."
  ;; I could alternatively use `command-error-function' for catching
  ;; errors
  (when (and (not ilog-changing-log-buffer-p)
             ilog-recent-commands)
    (if (string-match "\\` \\*Echo Area" (buffer-name))
        (setq ilog-last-command-changed-buffer-p 'echo)
      (setq ilog-last-command-changed-buffer-p (not (minibufferp))))))

(defun ilog-truncate-log-buffer ()
  "Truncate the log buffer to `ilog-log-max' lines."
  (let ((buf (get-buffer ilog-buffer-name)))
    (when (and buf
               (not (eq buf (current-buffer))) ; avoid truncation when log buffer is current
               (numberp ilog-log-max))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (forward-line (- ilog-log-max))
            (delete-region (point-min) (point))
	    (set-buffer-modified-p nil)))))))


(provide 'interaction-log)

;;; interaction-log.el ends here
