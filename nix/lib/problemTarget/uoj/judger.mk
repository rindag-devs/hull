all: judger

judger: judger.c
	gcc judger.c -o judger -O3 -std=gnu99
