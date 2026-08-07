;;; teams4e-demo.el --- Reproducible README demo for teams4e -*- lexical-binding: t; -*-

;;; Commentary:

;; Launch with:
;;   Emacs -Q --load tools/teams4e-demo.el
;;
;; The demo uses only the bundled mock tenant.  It never reads credentials or
;; contacts Microsoft Graph.

;;; Code:

(defconst teams4e-demo-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name)))))

(add-to-list 'load-path teams4e-demo-root)
(require 'teams4e)
(require 'server)

(setq inhibit-startup-screen t
      initial-scratch-message nil
      teams4e-backend-program
      (expand-file-name "bin/teams4e-graph" teams4e-demo-root)
      teams4e-mock-mode t
      teams4e-use-persistent-backend nil
      teams4e-cache-first nil
      teams4e-preview-on-move nil
      teams4e-mark-read-on-open nil
      teams4e-status-style 'symbols
      teams4e-meeting-enrichment-limit 32
      teams4e-mock-state-file
      (expand-file-name "teams4e-readme-mock.json" temporary-file-directory)
      teams4e-cache-file
      (expand-file-name "teams4e-readme-cache.sqlite3" temporary-file-directory)
      teams4e-state-file
      (expand-file-name "teams4e-readme-state.json" temporary-file-directory)
      teams4e-draft-directory
      (expand-file-name "teams4e-readme-drafts" temporary-file-directory)
      teams4e-image-cache-directory
      (expand-file-name "teams4e-readme-images" temporary-file-directory))

(dolist (path (list teams4e-mock-state-file
                    teams4e-cache-file
                    teams4e-state-file))
  (when (file-exists-p path) (delete-file path)))

(when (display-graphic-p)
  (dolist (pattern '("~/.emacs.d/elpa/*/moe-theme-*"
                     "~/.config/emacs/elpa/*/moe-theme-*"
                     "~/spacemacs/elpa/*/*/moe-theme-*"))
    (dolist (directory
             (file-expand-wildcards (expand-file-name pattern) t))
      (add-to-list 'custom-theme-load-path directory)))
  (condition-case nil
      (load-theme 'moe-dark t)
    (error (load-theme 'wombat t)))
  (menu-bar-mode -1)
  (tool-bar-mode -1)
  (scroll-bar-mode -1)
  (set-face-attribute 'default nil :family "SF Mono" :height 130)
  (set-frame-position nil 36 36)
  (set-frame-size nil 146 43)
  (set-frame-parameter nil 'title "teams4e - mock tenant"))

(setq server-name "teams4e-demo")
(when (server-running-p server-name)
  (server-force-delete server-name))
(server-start)

(teams4e-inbox)

(provide 'teams4e-demo)

;;; teams4e-demo.el ends here
