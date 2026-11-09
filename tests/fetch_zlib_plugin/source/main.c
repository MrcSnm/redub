#include <zlib.h>
#include <stdio.h>
#include <string.h>

int main(void)
{
	const char *src = "hello hello hello";
	unsigned char packed[128], out[128];
	uLongf packedLen = sizeof(packed), outLen = sizeof(out);
	if(compress(packed, &packedLen, (const Bytef*)src, (uLong)strlen(src) + 1) != Z_OK)
		return 1;
	if(uncompress(out, &outLen, packed, packedLen) != Z_OK)
		return 2;
	printf("%s (%s)\n", (char*)out, zlibVersion());
	return 0;
}
