all: idris hello
idris: idris.idr
	idris2 --cg chicken idris.idr -o idris

hello: hello.scm
	csc -k hello.scm
