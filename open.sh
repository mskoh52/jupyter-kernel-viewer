#!/usr/bin/env bash
if [ -n "$1" ]; then
  open "file:///Users/mkoh/src/jupyter-kernel-viewer/jupyter_kernel_viewer.html?token=$1"
else
  open "file:///Users/mkoh/src/jupyter-kernel-viewer/jupyter_kernel_viewer.html"
fi
