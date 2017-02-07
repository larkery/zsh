#!/usr/bin/env zsh

git config filter.encrypt.clean "openssl aes-256-cbc -a -pass file:$HOME/.zsh/history-password"
git config filter.encrypt.smudge "openssl aes-256-cbc -d -a -pass file:$HOME/.zsh/history-password"
git config merge.histdb.driver "zsh -c \"source ~/.zsh/sqlite-history.zsh; _histdb_merge %O %A %B\""

KEY="AAAAB3NzaC1yc2EAAAADAQABAAABAQC8B1DrrW4CIKEu+ZLkvk8C+1cdgMLHoDUpIzFaWhOiRimpsZ9KAX9a4LY0oCYziWCfxIKYILtz+Z93O/7zEyTQSa1Hu0ygh5t05qBY//o7NwhdvMikw5mGEgEcXgE8VC0tlfgZmz+c7n0sRwAQW2Gezqo9L5LhKaxtpNXWcYP/RYahR/RYqG7nK/cErurNG2qZznawWFnYivB+MSX2J3dl0dJXe8zsLmKens0wuDbsxoRJrvL24TlPktXWzGz324PEiCK5lvGdbl/s6wVAzJHHagqyschqGq7NXyI+jNUgJB8SxisHjYDq6LOJyc2i6VXZ39N1oqcDZ3I1QF78s0tD"

git config filter.sshcrypt.clean "$HOME/.zsh/encrypt-filter encrypt $KEY"
git config filter.sshcrypt.smudge "$HOME/.zsh/encrypt-filter decrypt $KEY"
