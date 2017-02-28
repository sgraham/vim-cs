Chromium Codesearch Query for Vim
---------------------------------

Quick port of https://github.com/karlinjf/ChromiumXRefs/ to Vim.

![Screenshot](/vim-cs.gif)

To use it:

    cd %USERPROFILE%\vimfiles
    git clone https://github.com/sgraham/vim-cs.git

or:

    cd ~/.vim
    git clone https://github.com/sgraham/vim-cs.git bundle/alt

Then

    set runtimepath^=~/vimfiles/vim-cs

to your _vimrc.

Then, Ctrl-\ will load cs.chromium.org info into a Quickfix buffer in Vim so you
can jump around.
