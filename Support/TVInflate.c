#include "TVInflate.h"
#include <zlib.h>
#include <stdlib.h>
#include <limits.h>
int ctv_inflate(const uint8_t *input,size_t size,uint8_t **output,size_t *length,size_t limit) {
    if(!input || !output || !length || size>UINT_MAX || limit<32768) return -1;
    *output=NULL; *length=0;
    z_stream stream={0};
    if(inflateInit2(&stream,15+32)!=Z_OK) return -1;
    size_t capacity=32768,used=0; uint8_t *data=malloc(capacity);
    if(!data){inflateEnd(&stream);return -1;}
    stream.next_in=(Bytef*)input;stream.avail_in=(uInt)size;
    int status=Z_OK;
    while(status==Z_OK){
        if(used==capacity){
            if(capacity>=limit){status=Z_MEM_ERROR;break;}
            size_t next=capacity>limit/2?limit:capacity*2;
            uint8_t *grown=realloc(data,next);if(!grown){status=Z_MEM_ERROR;break;}data=grown;capacity=next;
        }
        stream.next_out=data+used;stream.avail_out=(uInt)(capacity-used);
        status=inflate(&stream,Z_NO_FLUSH);used=capacity-stream.avail_out;
    }
    inflateEnd(&stream);
    if(status!=Z_STREAM_END){free(data);return -1;}
    *output=data;*length=used;return 0;
}
