;;; teams4e-demo.el --- Interactive synthetic teams4e demo -*- lexical-binding: t; -*-

;;; Commentary:
;; Launch in a separate Emacs, not your working session:
;;   emacs -Q -L /path/to/moe-theme.el -L /path/to/agent-shell \
;;     --load tools/teams4e-demo.el
;; See tools/README.md for the reproducible screenshot workflow.

;;; Code:
(defconst teams4e-demo-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name)))))
(defconst teams4e-demo-data (make-temp-file "teams4e-demo-" t))
(add-to-list 'load-path teams4e-demo-root)
(require 'teams4e)

(setq inhibit-startup-screen t
      initial-scratch-message nil
      teams4e-mock-mode t
      teams4e-use-persistent-backend nil
      teams4e-cache-first nil
      teams4e-preview-on-move nil
      teams4e-mark-read-on-open nil
      teams4e-compose-editor 'org
      teams4e-mock-state-file (expand-file-name "mock.json" teams4e-demo-data)
      teams4e-cache-file (expand-file-name "cache.sqlite3" teams4e-demo-data)
      teams4e-state-file (expand-file-name "state.json" teams4e-demo-data)
      teams4e-draft-directory (expand-file-name "drafts" teams4e-demo-data)
      teams4e-image-cache-directory (expand-file-name "images" teams4e-demo-data)
      teams4e-credentials-file (expand-file-name "no-credentials.json" teams4e-demo-data)
      teams4e-token-command nil
      teams4e-bootstrap-program nil)

(unless (zerop (call-process "python3" nil "*Demo seed*" nil
                            (expand-file-name "tools/seed-demo.py" teams4e-demo-root)
                            teams4e-mock-state-file))
  (error "Cannot initialize synthetic tenant; see *Demo seed*"))

(when (require 'agent-shell-markdown nil t)
  (setq teams4e-message-renderer 'agent-shell-markdown))

(when (display-graphic-p)
  (require 'moe-theme)
  (unless (find-font (font-spec :family "Iosevka"))
    (error "Install Iosevka to use this demo's appearance"))
  (let ((moe-theme--need-reload-theme t)) (moe-dark))
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-frame-font "Iosevka-12" nil t)
  (set-frame-size nil 180 46)
  (set-frame-parameter nil 'title "teams4e - synthetic tenant"))

(teams4e-inbox)
(provide 'teams4e-demo)
;;; teams4e-demo.el ends here
