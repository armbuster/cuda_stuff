/* CUDA blur
 * Kevin Yuh, 2014 */

#include <cstdio>
#include <cuda_runtime.h>
#include <cufft.h>
#include <math.h>
#include "fft_convolve.cuh"


/* 
Atomic-max function. You may find it useful for normalization.

We haven't really talked about this yet, but __device__ functions not
only are run on the GPU, but are called from within a kernel.

Source: 
http://stackoverflow.com/questions/17399119/
cant-we-use-atomic-operations-for-floating-point-variables-in-cuda
*/
__device__ static float atomicMax(float* address, float val)
{
    int* address_as_i = (int*) address;
    int old = *address_as_i, assumed;
    do {
        assumed = old;

        // if the value at address_as_i is still the value of assumed
        // perform the max operation, store the result at the address
        // and return assumed
        
        // if the value at address_as_i has changed since we loaded it
        // on line 24, return this new value and assign it to old.
        // Then assumed != old, so we set assumed = old and try again.
        old = ::atomicCAS(address_as_i, assumed,
            __float_as_int(::fmaxf(val, __int_as_float(assumed))));
    } while (assumed != old);
    return __int_as_float(old);
}



__global__
void
cudaProdScaleKernel(const cufftComplex *raw_data, const cufftComplex *impulse_v, 
    cufftComplex *out_data, int padded_length, const unsigned int work_per_thread) {

        int tidx = blockIdx.x * blockDim.x + threadIdx.x;
        tidx *= work_per_thread; // space out threads by work_per_thread

        for(int i = 0; i < work_per_thread; i++){
            if (tidx <= padded_length - 1)
            {
                out_data[tidx].x = raw_data[tidx].x * impulse_v[tidx].x - raw_data[tidx].y * impulse_v[tidx].y;
                out_data[tidx].y = raw_data[tidx].x * impulse_v[tidx].y + raw_data[tidx].y * impulse_v[tidx].x;
                
                // scale by length of sequence, because for X of length n, IFFT(FFT(X)) = n*X
                out_data[tidx].x /= padded_length;
                out_data[tidx].y /= padded_length;
                tidx += 1;
            }
        }



    /* TODO: Implement the point-wise multiplication and scaling for the
    FFT'd input and impulse response. 

    Recall that these are complex numbers, so you'll need to use the
    appropriate rule for multiplying them. 

    Also remember to scale by the padded length of the signal
    (see the notes for Question 1).

    As in Assignment 1 and Week 1, remember to make your implementation
    resilient to varying numbers of threads.

    */
    
}

__device__
void
get_thread_max(cufftComplex *data, int padded_length){
    
    // gets maximum value for each thread, necessary when
    // array is larger than the total # of threads

    // for a given thread idx, puts the maximum of 
    // data[idx + k(# threads)] for each k where
    // (idx + k(# threads)) < (padded_length / 2) at data[idx]

    int idx = blockDim.x * blockIdx.x + threadIdx.x;
    int total = ceil( (float) padded_length / (gridDim.x * blockDim.x));
    float current_max = fabs(data[idx].x);
    
    int current_pos = idx;
    for(int k = 1; k < total; k++){
        current_pos += (gridDim.x * blockDim.x);
        if (current_pos < padded_length){
            current_max = max(current_max, data[current_pos].x);
        }
    }
    data[idx].x = current_max;
    }







__global__
void
cudaMaximumKernel(cufftComplex *out_data, float *max_abs_val,
    int padded_length, int offset) {

    /* TODO 2: Implement the maximum-finding.
    You'll likely find the above atomicMax function helpful.
    (CUDA's atomicMax function doesn't work for floating-point values.)
    It's based on two principles:
        1) From Week 2, any atomic function can be implemented using
        atomic compare-and-swap.
        2) One can "represent" floating-point values as integers in
        a way that preserves comparison, if the sign of the two
        values is the same. (see http://stackoverflow.com/questions/
        29596797/can-the-return-value-of-float-as-int-be-used-to-
        compare-float-in-cuda)

    */
    extern __shared__ float shmem[];
    unsigned int idx = offset + blockIdx.x * (blockDim.x * 2) + threadIdx.x;
    float first;
    float second;

    if (idx < padded_length){
        first = fabs(out_data[idx].x);
    }
    else{
        first = 0;
    }
    
    if (idx + blockDim.x < padded_length){
        second = fabs(out_data[idx + blockDim.x].x);
    }
    else{
        second = 0;
    }


    shmem[threadIdx.x] = ::fmaxf(first, second);
    __syncthreads();

    int rem = blockDim.x % 2;
    unsigned int s = blockDim.x / 2 + rem;
    while(s > 0){
        if (threadIdx.x < s){
            shmem[threadIdx.x] = ::fmaxf(shmem[threadIdx.x], shmem[threadIdx.x + s]);
        }

        __syncthreads();
        rem = s % 2;
        if(s == 1) rem = 0;
        s = s / 2 + rem; // rounded up integer division
    }
    
    atomicMax(max_abs_val, shmem[0]);
}

__global__
void
cudaDivideKernel(cufftComplex *out_data, float max_abs_val,
    int padded_length, int offset) {

    unsigned int idx = offset + blockIdx.x * blockDim.x + threadIdx.x;
    out_data[idx].x /= max_abs_val;
    //out_data[idx].x /= 1;

    /* TODO 2: Implement the division kernel. Divide all
    data by the value pointed to by max_abs_val. 

    This kernel should be quite short.
    */

}


void cudaCallProdScaleKernel(const unsigned int blocks,
        const unsigned int threadsPerBlock,
        const cufftComplex *raw_data,
        const cufftComplex *impulse_v,
        cufftComplex *out_data,
        const unsigned int padded_length) {


            int N = ceil( (float) padded_length / (blocks * threadsPerBlock));
            cudaProdScaleKernel<<<blocks, threadsPerBlock>>>(
                raw_data,
                impulse_v,
                out_data,
                padded_length,
                N
            );
        
    /* TODO: Call the element-wise product and scaling kernel. */
        }

void cudaCallMaximumKernel(const unsigned int blocks,
        const unsigned int threadsPerBlock,
        cufftComplex *out_data,
        float *max_abs_val,
        const unsigned int padded_length) {

        int offset = (blocks * threadsPerBlock * 2);
        int num_calls = ceil((float)padded_length / offset);
        size_t shmem_size = threadsPerBlock * sizeof(float);

        for (int i = 0; i < num_calls; i++)
        {
            cudaMaximumKernel<<<blocks, threadsPerBlock, shmem_size>>>(
                out_data,
                max_abs_val,
                padded_length,
                i * offset
            );
        }

        



}


void cudaCallDivideKernel(const unsigned int blocks,
        const unsigned int threadsPerBlock,
        cufftComplex *out_data,
        float max_abs_val,
        const unsigned int padded_length) {
        
        int num_threads = (blocks * threadsPerBlock);
        int num_calls = ceil((float)padded_length / num_threads);

        for (int i = 0; i < num_calls; i++)
        {
            cudaDivideKernel<<<blocks, threadsPerBlock>>>(
                out_data,
                max_abs_val,
                padded_length,
                i * num_threads
            );
        }
}
