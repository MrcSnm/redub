#include <SDL3/SDL.h>
#include <stdio.h>

int main(void)
{
	int version = SDL_GetVersion();
	printf("SDL %d.%d.%d (%s)\n",
		SDL_VERSIONNUM_MAJOR(version),
		SDL_VERSIONNUM_MINOR(version),
		SDL_VERSIONNUM_MICRO(version),
		SDL_GetRevision());

	if(!SDL_Init(SDL_INIT_EVENTS))
	{
		fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
		return 1;
	}
	SDL_Quit();
	return 0;
}
