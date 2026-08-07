;;; msteams.el --- A keyboard-driven Microsoft Teams client -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later

;; Author: guibor
;; Maintainer: guibor
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: comm, tools
;; URL: https://github.com/guibor/msteams.el

;;; Commentary:

;; msteams provides a mu4e-inspired inbox and singleton reader for Microsoft
;; Teams chats and channels.  It delegates Microsoft Graph OAuth to an external
;; token provider and bundles a standard-library-only Python Graph adapter.

;;; Code:

(require 'msteams-config)
(require 'msteams-ui)
(require 'msteams-advanced)
(require 'msteams-evil)

(provide 'msteams)

;;; msteams.el ends here
