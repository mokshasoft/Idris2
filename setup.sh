#!/bin/sh

# Setup the compiler path
export PATH="$PATH:/home/l337/.idris2/bin/"

# Setup so that the Chicken compiler finds chicken.h
# Idris2 compiles with: /usr/bin/env -S csc <chicken>.scm -o <outfile>
# which generates a C file which includes chicken.h that is routed through gcc with
# an incorrect parameter -I/usr/include/chicken/chicken. It should have been
# -I/usr/include/chicken/. Set the C_INCLUDE_PATH to temporarily fix the problem.
export C_INCLUDE_PATH=/usr/include/chicken/

