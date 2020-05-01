all: idris hello
idris: idris.idr
	idris2 --cg chicken idris.idr -o idris

hello: hello.scm
	csc -k hello.scm

clean:
	rm -f idris idris.o idris.c hello hello.o hello.c 
