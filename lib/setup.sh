#!/bin/bash

set -xe

CXXFLAGS="-I. -fPIC -O3 -DNDEBUG -DHAVE_ZLIB -DKENLM_MAX_ORDER=6 -g -lz $CXXFLAGS"

build_lib () {
	if [ ! -d "kenlm" ]
	then
		if [ ! -f "kenlm.tar.gz" ]
		then
			echo -n "Downloading... "
			wget http://kheafield.com/code/kenlm.tar.gz 2> /dev/null
			echo "Done."
		fi
		echo -n "Extracting... "
		tar xfv kenlm.tar.gz > /dev/null
		echo "Done."
	fi
	
	echo -n "Building"
	cp kenlm.cc kenlm/.
	cd kenlm/
	
	#Grab all cc files in these directories except those ending in test.cc or main.cc
	objects=""
	for i in util/double-conversion/*.cc util/*.cc lm/*.cc; do
		if [ "${i%test.cc}" == "$i" ] && [ "${i%main.cc}" == "$i" ]; then
			g++ $CXXFLAGS -c $i -o ${i%.cc}.o
			objects="$objects ${i%.cc}.o"
			echo -n "."
		fi
	done
	
	build
}

build () {
	echo -n "Building"
	cp kenlm.cc kenlm/.
	cd kenlm/
	objects=""
	for i in util/double-conversion/*.cc util/*.cc lm/*.cc; do
		if [ "${i%test.cc}" == "$i" ] && [ "${i%main.cc}" == "$i" ]; then
			objects="$objects ${i%.cc}.o"
		fi
	done
	g++ $CXXFLAGS -Wall -c kenlm.cc -o kenlm.o
	objects="$objects kenlm.o"
	echo -n "."
	g++ $CXXFLAGS -Wall demo.cc $objects -o demo 
	g++ $CXXFLAGS -Wall -shared -o libkenlm.so $objects
	echo "."
	
	cp libkenlm.so ../.
	cd ..
}

install () {
	if [ ! -f libkenlm.so ]
	then
		build
	else
		mkdir -p ~/.local/lib/
		cp libkenlm.so ~/.local/lib/.
		echo "Installed library to '$HOME/.local/lib/libkenlm.so',"
		echo "add '$HOME/.local/lib' to 'LD_LIBRARY_PATH':"
		echo "  export LD_LIBRARY_PATH=\"$HOME/.local/lib:\$LD_LIBRARY_PATH\""
		echo "or move the library to the global library path."
	fi
}

clean () {
	if [ -d "kenlm" ]
	then
		rm -r "kenlm"
	fi
	if [ -f "kenlm.tar.gz" ]
	then
		rm "kenlm.tar.gz"
	fi
}

$1