.PHONY: hull-uoj-prepare

all: hull-uoj-prepare
	./hull-uoj-prepare

hull-uoj-prepare: hull-uoj-prepare.c
	gcc hull-uoj-prepare.c -o hull-uoj-prepare -O3 -std=c99
