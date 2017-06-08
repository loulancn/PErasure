#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>
#include <iostream>
#include <cuda.h>
#include "jerasure.h"
extern "C"{
	#include "gf_rand.h"
}

using namespace std;

#define talloc(type, num) (type *) malloc(sizeof(type)*(num))

//__global__ void smpe(int k, int w, int *bitmatrixDevice, int destId, char *dataDevice, char *codingDevice, int dataSize, int numOfLong) {
	//__shared__ char sharedData[dataSize];
	//int blockNumInGrid, threadsPerBlock, threadNumInBlock, tId;
	//blockNumInGrid = blockIdx.x + gridDim.x * blockIdx.y;
	//threadsPerBlock = blockDim.x * blockDim.y;
	//threadNumInBlock = threadIdx.x + blockDim.x * threadIdx.y;
	//tId = blockNumInGrid * threadsPerBlock + threadNumInBlock;
	
	
	//if(tId * sizeof(long) >= dataSize)
		//return;
	
	//for(dataIdx = 0; dataIdx < k; dataIdx++)
		//memcpy((char *)&sharedData, (char *)(dataDevice + dataIdx * dataSize + tId * ), sizeof(long));
		////sharedData = *(dataDevice + dataIdx * psize * w)
		//__syncthreads();
		//for(i=0; i<w; i++) 
			//sdIndex = dataIdx + i * psize + colIndex;
			//temp ^= (*(bitmatrixDevice + index) & sharedData[sdIndex]);
			//index++;
		//__syncthreads();
	//codingDevice = 
	
//}

__global__ void gmpe(int k, int w, int *bitmatrixDevice, int destId, long *dataDevice, long *codingDevice, int dataSize, int numOfLong) {
	
	int blockNumInGrid, threadsPerBlock, threadNumInBlock, tId;
	blockNumInGrid = blockIdx.x + gridDim.x * blockIdx.y;
	threadsPerBlock = blockDim.x * blockDim.y;
	threadNumInBlock = threadIdx.x + blockDim.x * threadIdx.y;
	tId = blockNumInGrid * threadsPerBlock + threadNumInBlock;
	
	int longIndex = tId % numOfLong;
	int index, dataIdx, i, j;
	long temp;
	long *codPtr, *dtPtr, *innerDtPtr;
	
	if( tId >= numOfLong)
		return;
	
	for(i=0; i<w; i++){
		codPtr = codingDevice + destId * w * numOfLong + i * numOfLong;
		index = destId * k * w * w + i * k * w;
		temp = 0;
		for(dataIdx=0; dataIdx<k; dataIdx++){
			dtPtr = dataDevice + dataIdx * w * numOfLong;
			for(j=0; j<w; j++){
				if(bitmatrixDevice[index]){
					innerDtPtr = dtPtr + j * numOfLong;
					temp ^= innerDtPtr[longIndex];
				}
				index++;
			}
		}
		codPtr[longIndex] = temp;
	}
}


void extendCodingDevice(long *codingTemp, long *coding, int i, int m, int psize, int offset, int rows){
	int k, j;
	
	for(k=0; k<m; k++)	
		for(j=0; j<rows; j++)
			memcpy((coding + k * psize * rows + psize * j + i * offset), (codingTemp + k * offset * rows + offset * j), sizeof(long) * offset);
}

int main(int argc, char **argv){

	unsigned int m, k, w, i, j, d, r, l, seed, psize;
	unsigned int round;
	int *matrix, *bitmatrix, *bitmatrixDevice;
	clock_t start;
	long *data, *dataDevice, *dataTemp, *coding, *codingDevice, *codingTemp;
    
    srand(time(NULL));

    if(argc != 5) {
        fprintf(stderr, "Please add arguments k, m, w and size\n");
        exit(1);
    }
	if(sscanf(argv[1], "%d", &k) == 0 || k <= 0) {
		fprintf(stderr, "Wrong k\n");
		exit(1);
	}
	if (sscanf(argv[2], "%d", &m) == 0 || m <= 0) {
		fprintf(stderr, "Wrong m\n");
		exit(1);
	}
	if (sscanf(argv[3], "%d", &w) == 0 || w <= 0 || w > 31) {
		fprintf(stderr, "Wrong w\n");
		exit(1);
	}
	if (sscanf(argv[4], "%d", &psize) == 0) {
		fprintf(stderr, "Wrong packetsize\n");
		exit(1);
	}
	if((k + m) > (1 << w)) {
		fprintf(stderr, "Wrong w, the following must hold: m + k <= 2^w\n");
		exit(1);
	}
	psize = psize/sizeof(long);
	
//    Creating matrix and BDM
	seed = rand();
	MOA_Seed(seed);
	matrix = talloc(int, m*k);
	for (i = 0; i < m; i++) {
		for (j = 0; j < k; j++) {
			matrix[i*k+j] = galois_single_divide(1, i ^ (m + j), w);
		}
	}

	bitmatrix = jerasure_matrix_to_bitmatrix(k, m, w, matrix);

//    Generating fake random data
	data = talloc(long , k*w*psize);
	for (i = 0; i < k; i++) {
		for(j=0; j< w*psize; j++)
			*(data + i*psize*w + j) = 97 + rand()%26;
	}

	coding = talloc(long , m * w * psize);
	
    //	Allocating GPU memory
    
    cudaMalloc(&bitmatrixDevice, m*k*w*w*sizeof(int));
    cudaMemcpy(bitmatrixDevice, bitmatrix, m*k*w*w*sizeof(int), cudaMemcpyHostToDevice);
    
    //	Compute number of rounds
    
    size_t free, total;
    cudaMemGetInfo(&free, &total);
    
    round = ceil((float)(psize * w * (k + m) * sizeof(long)) / free);

    printf("Free mem: %lu\n", free);
    
	dataTemp = talloc(long , k * w * (psize/round));
	
	codingTemp = talloc(long, m * w * (psize/round));
	
	start = clock();

    for(i = 0; i < round; i++){
	
		// load data chunks
		if(round > 1){
			for(d = 0; d < k; d++)
				for(r = 0; r < w; r++)
					for(l = 0; l < psize / round; l++)
						*(dataTemp + d * w *(psize/round) + r * (psize/round) + l) = *(data + d * w * psize + i * psize/round + r * psize + l);
						
			cudaMalloc(&dataDevice, k * w * (psize/round) * sizeof(long));
			cudaMalloc(&codingDevice, m * w * (psize/round) * sizeof(long));
			cudaMemcpy(dataDevice, dataTemp, k * w * (psize/round) * sizeof(long), cudaMemcpyHostToDevice);
			cudaMemcpy(codingDevice, coding, m * w * (psize/round) * sizeof(long), cudaMemcpyHostToDevice);
		}else{
			cudaMalloc(&dataDevice, k * w * (psize/round) * sizeof(long));
			cudaMalloc(&codingDevice, m * w * (psize/round) * sizeof(long));
			cudaMemcpy(dataDevice, data, k * w * (psize/round) * sizeof(long), cudaMemcpyHostToDevice);
			cudaMemcpy(codingDevice, codingTemp, m * w * (psize/round) * sizeof(long), cudaMemcpyHostToDevice);
		}
		start = clock();
		for(j = 0; j < m; j++)
			//smpe<<<dimGrid, dimBlock>>>(k, w, bitmatrixDevice + j * w * w * k, j, dataDevice, codingDevice, (psize/round) * w, sizeof(long));
			gmpe<<<1024, 1024>>>(k, w, bitmatrixDevice, j, dataDevice, codingDevice, (psize/round) * w, (psize/round));
			
		// copy coding back to main memory
		printf("Encoding complete, time elapsed: %.8fs\n", (clock() - (float)start) / CLOCKS_PER_SEC);

		cudaMemcpy(codingTemp, codingDevice, m * w * (psize/round) * sizeof(long), cudaMemcpyDeviceToHost);
		extendCodingDevice(codingTemp, coding, i, m, psize, (psize/round), w);

		cudaFree(dataDevice);
		cudaFree(codingDevice);
	}
    //printf("Encoding complete, time elapsed: %.4fs\n", (clock() - (float)start) / CLOCKS_PER_SEC);

    ////Status after coding
    //for(i = 0; i < k; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)*(data + i*w*psize + j));
		//printf("\n");
	//}
	//printf("\n");
	
	//for(i = 0; i < m; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)*(coding + i*w*psize + j));
		//printf("\n");
	//}
	//printf("\n");
    
    //// Erasing random m devices
    //int random[m+1];
    //bool flag;
    //for(i = 0; i < m;) {
        //r = MOA_Random_W(w, 1) % (k + m);
        //flag = true;
        //for (j = 0; j < m; j++)
            //if (r == random[j]) flag = false;
        //if (flag) {
            //random[i] = r;
            //i++;
        //}
    //}
    //random[i] = -1;
    //for(i = 0; i < m; i++) {
        //if (random[i] < k)
            //bzero((data + random[i] * w * psize), w*psize * sizeof(long));
        //else bzero((coding + (random[i] - k) * w * psize), w*psize * sizeof(long));
    //}
    //printf("Erased %d random devices\n", m);
       
    //for(i = 0; i < k; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)*(data + i*w*psize + j));
		//printf("\n");
	//}
	//printf("\n");
	
	//for(i = 0; i < m; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)*(coding + i*w*psize + j));
		//printf("\n");
	//}
	//printf("\n");
	
	//char **data2, **coding2;
	
	//data2 = talloc(char *, k);
	//for (i = 0; i < k; i++) {
		//data2[i] = talloc(char, psize*w);
	//}

	//coding2 = talloc(char *, m);
	//for (i = 0; i < m; i++) {
		//coding2[i] = talloc(char, psize*w);
	//}
	
	//for(i = 0; i < k; i++){
		//for(j = 0; j < w * psize; j++)
			//data2[i][j] = (char)*(data + i*w*psize + j);
	//}
	
	//for(i = 0; i < m; i++){
		//for(j = 0; j < w * psize; j++)
			//coding2[i][j] = (char)*(coding + i*w*psize + j);
	//}
	
	//start = clock();
	//jerasure_bitmatrix_decode(k, m, w, bitmatrix, 0, random, data2, coding2, w*psize, psize);
	//printf("Devices recovered, time elapsed: %.4fs\n", (clock() - (float)start) / CLOCKS_PER_SEC);
	
	//for(i = 0; i < k; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)data2[i][j]);
		//printf("\n");
	//}
	//printf("\n");
	
	//for(i = 0; i < m; i++){
		//for(j = 0; j < w * psize; j++)
			//printf("%02x ", (unsigned char)coding2[i][j]);
		//printf("\n");
	//}
	//printf("\n");

    return 0;
}
