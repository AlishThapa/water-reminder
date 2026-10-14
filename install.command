#!/bin/zsh
# Double-click in Finder to build, install and schedule; same as running ./install.sh.
exec "${0:A:h}/install.sh" "$@"
