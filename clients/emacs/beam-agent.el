;;; beam-agent.el --- Thin BeamAgent runtime client -*- lexical-binding: t; -*-

(require 'json)
(require 'subr-x)

(defgroup beam-agent nil "Observe and control BeamAgent goals." :group 'tools)
(defcustom beam-agent-host "127.0.0.1" "BeamAgent API host." :type 'string)
(defcustom beam-agent-port 0 "BeamAgent JSON-lines API port." :type 'integer)
(defcustom beam-agent-token "" "BeamAgent bearer token." :type 'string)

(defvar beam-agent--process nil)
(defvar beam-agent--sequence 0)
(defvar beam-agent--buffer "")
(defvar beam-agent-events-buffer "*BeamAgent Events*")

(defun beam-agent-connect ()
  "Connect to the configured BeamAgent JSON-lines listener."
  (interactive)
  (when (process-live-p beam-agent--process) (delete-process beam-agent--process))
  (setq beam-agent--process
        (make-network-process :name "beam-agent" :host beam-agent-host :service beam-agent-port
                              :coding 'utf-8 :filter #'beam-agent--filter :noquery t))
  (message "BeamAgent connected"))

(defun beam-agent--filter (_process chunk)
  (setq beam-agent--buffer (concat beam-agent--buffer chunk))
  (let ((lines (split-string beam-agent--buffer "\n")))
    (setq beam-agent--buffer (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (with-current-buffer (get-buffer-create beam-agent-events-buffer)
          (goto-char (point-max)) (insert line "\n"))))))

(defun beam-agent-command (command &optional arguments)
  "Send COMMAND with optional ARGUMENTS through the versioned runtime protocol."
  (unless (process-live-p beam-agent--process) (beam-agent-connect))
  (setq beam-agent--sequence (1+ beam-agent--sequence))
  (process-send-string
   beam-agent--process
   (concat (json-serialize
            `((version . 1) (request_id . ,(format "emacs-%d" beam-agent--sequence))
              (command . ,command) (arguments . ,(or arguments '())) (token . ,beam-agent-token)))
           "\n")))

(defun beam-agent-status () (interactive) (beam-agent-command "status") (pop-to-buffer beam-agent-events-buffer))
(defun beam-agent-cancel () (interactive) (beam-agent-command "cancel"))
(defun beam-agent-submit (prompt) (interactive "sAsk BeamAgent: ")
  (beam-agent-command "submit" `((prompt . ,prompt))))

(provide 'beam-agent)
;;; beam-agent.el ends here
