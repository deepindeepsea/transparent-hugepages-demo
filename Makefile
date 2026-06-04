JAVAC ?= javac
CC ?= gcc
CFLAGS ?= -O2 -Wall

.PHONY: all java c clean

all: c java

c: src/microbench.c
	$(CC) $(CFLAGS) -o microbench src/microbench.c

java: src/LatBench.java
	$(JAVAC) -d . src/LatBench.java

clean:
	rm -f microbench *.class
