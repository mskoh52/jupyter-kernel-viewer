if exists('g:loaded_jupyter') | finish | endif
let g:loaded_jupyter = 1

lua require('jupyter')
