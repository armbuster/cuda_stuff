#include <cassert>
#include <cuda_runtime.h>
#include "transpose_device.cuh"


// TODO:
// implemement optimized version of transpose
// use nvvp (installed locally already)
// https://discuss.mxnet.io/t/using-nvidia-profiling-tools-visual-profiler-and-nsight-compute/2801





/*
 * TODO for all kernels (including naive):
 * Leave a comment above all non-coalesced memory accesses and bank conflicts.
 * Make it clear if the suboptimal access is a read or write. If an access is
 * non-coalesced, specify how many cache lines it touches, and if an access
 * causes bank conflicts, say if its a 2-way bank conflict, 4-way bank
 * conflict, etc.
 *
 * Comment all of your kernels.
 */


/*
 * Each block of the naive transpose handles a 64x64 block of the input matrix,
 * with each thread of the block handling a 1x4 section and each warp handling
 * a 32x4 section.
 *
 * If we split the 64x64 matrix into 32 blocks of shape (32, 4), then we have
 * a block matrix of shape (2 blocks, 16 blocks).
 * Warp 0 handles block (0, 0), warp 1 handles (1, 0), warp 2 handles (0, 1),
 * warp n handles (n % 2, n / 2).
 *
 * This kernel is launched with block shape (64, 16) and grid shape
 * (n / 64, n / 64) where n is the size of the square matrix.
 *
 * You may notice that we suggested in lecture that threads should be able to
 * handle an arbitrary number of elements and that this kernel handles exactly
 * 4 elements per thread. This is OK here because to overwhelm this kernel
 * it would take a 4194304 x 4194304    matrix, which would take ~17.6TB of
 * memory (well beyond what I expect GPUs to have in the next few years).
 */
__global__
void naiveTransposeKernel(const float *input, float *output, int n) {
    // TODO: do not modify code, just comment on suboptimal accesses

    const int i = threadIdx.x + 64 * blockIdx.x;
    int j = 4 * threadIdx.y + 64 * blockIdx.y;
    const int end_j = j + 4;

    // left side is non coalesced (stride n accesses)
    // right side could be coalesced if __syncthreads() was added each iteration
    for (; j < end_j; j++)
        output[j + n * i] = input[i + n * j];
}

__global__
void shmemTransposeKernel(const float *input, float *output, int n) {
    // TODO: Modify transpose kernel to use shared memory. All global memory
    // reads and writes should be coalesced. Minimize the number of shared
    // memory bank conflicts (0 bank conflicts should be possible using
    // padding). Again, comment on all sub-optimal accesses.

    __shared__ float shared_mem[64][66];

    int shift = 0;
    if (threadIdx.x > 31) shift +=1; // padding to prevent memory bank conflicts
    // leave single gap between elements 0-31 in shared mem, 32-63

    int i = threadIdx.x + 64 * blockIdx.x;
    int j = 4 * threadIdx.y + 64 * blockIdx.y;
    int end_j = j + 4;
    
    for (int k = 0; j < end_j; j++){

        shared_mem[4 * threadIdx.y + k][threadIdx.x + shift] = input[j * n + i];
        k++;
    }
    
    __syncthreads();
    j = 4 * threadIdx.y + 64 * blockIdx.x;
    i = threadIdx.x + 64 * blockIdx.y;
    end_j = j + 4;
    shift = 0;
    if (threadIdx.y > 7) shift += 1;
    

    for(int k = 0; j < end_j; j++){
        output[n * j + i] = shared_mem[threadIdx.x][4 * threadIdx.y + k + shift];
        k++;
    }
}





__global__
void optimalTransposeKernel(const float *input, float *output, int n) {
    // only difference between shmem implementation and this is that
    // loops are removed. Seems to improve speed by about 10%
    // same or faster than memcpy.

    __shared__ float shared_mem[64][66];

    int shift = 0;
    if (threadIdx.x > 31) shift +=1; // padding to prevent memory bank conflicts
    // leave single gap between elements 0-31 in shared mem, 32-63

    int i = threadIdx.x + 64 * blockIdx.x;
    int j = 4 * threadIdx.y + 64 * blockIdx.y;

    shared_mem[4 * threadIdx.y][threadIdx.x + shift] = input[j * n + i];
    shared_mem[4 * threadIdx.y + 1][threadIdx.x + shift] = input[(j+1) * n + i];
    shared_mem[4 * threadIdx.y + 2][threadIdx.x + shift] = input[(j+2) * n + i];
    shared_mem[4 * threadIdx.y + 3][threadIdx.x + shift] = input[(j+3) * n + i];


    __syncthreads();
    j = 4 * threadIdx.y + 64 * blockIdx.x;
    i = threadIdx.x + 64 * blockIdx.y;
    shift = 0;
    if (threadIdx.y > 7) shift += 1;

    output[n * j + i] = shared_mem[threadIdx.x][4 * threadIdx.y + shift];
    output[n * (j+1) + i] = shared_mem[threadIdx.x][4 * threadIdx.y + 1 + shift];
    output[n * (j+2) + i] = shared_mem[threadIdx.x][4 * threadIdx.y + 2 + shift];
    output[n * (j+3) + i] = shared_mem[threadIdx.x][4 * threadIdx.y + 3 + shift];
}

void cudaTranspose(
    const float *d_input,
    float *d_output,
    int n,
    TransposeImplementation type)
{
    if (type == NAIVE) {
        dim3 blockSize(64, 16);
        dim3 gridSize(n / 64, n / 64);
        naiveTransposeKernel<<<gridSize, blockSize>>>(d_input, d_output, n);
    }
    else if (type == SHMEM) {
        dim3 blockSize(64, 16);
        dim3 gridSize(n / 64, n / 64);
        shmemTransposeKernel<<<gridSize, blockSize>>>(d_input, d_output, n);
    }
    else if (type == OPTIMAL) {
        dim3 blockSize(64, 16);
        dim3 gridSize(n / 64, n / 64);
        optimalTransposeKernel<<<gridSize, blockSize>>>(d_input, d_output, n);
    }
    // Unknown type
    else
        assert(false);
}
