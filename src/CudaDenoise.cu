﻿#include "CudaDenoise.hpp"

#include <cuda_runtime.h>
#include <cufft.h>


#include <cassert>

#include <CudaMemory.hpp>
#include <ErrChecker.hpp>

constexpr float k16KHz = 16e3;

template <typename T> T divUp(T a, T b) { return a / b + 1; }

namespace gpudenoise {

__global__ void lowPassKernel(cufftComplex *fft, int cut_off, int length) {

  const int tid_init = blockIdx.x * blockDim.x + threadIdx.x;
  // Utilize cache lines with stride loop
  const int stride = gridDim.x * blockDim.x;

  for (int tid = tid_init; tid < length; tid += stride) {
    const int curr_freq = (tid <= (length >> 1)) ? tid : length - tid;
    if (curr_freq < cut_off) {
      continue;
    }
    // Cut the frequencies above the cutoff threshold
    fft[tid].x = 0.0f;
    fft[tid].y = 0.0f;
  }
}

static inline int calculateCutoffFrequency(const int sample_rate, const int signal_length){
    const int freq_resolution = divUp(sample_rate,signal_length);
    return k16KHz/freq_resolution;
}

static inline void cudaFftSingleDim(size_t signal_length, float *dev_signal, cufftComplex *fourier_transf){

    cufftHandle handler_fft;
    CUFFT_CHECK(cufftPlan1d(&handler_fft, signal_length, CUFFT_R2C, 1));
    CUFFT_CHECK(cufftExecR2C(handler_fft, dev_signal, fourier_transf));
    CUFFT_CHECK(cufftDestroy(handler_fft));
}

static inline void cudaFftSingleDimInverse(size_t fft_ptr_length, float *dev_signal, cufftComplex *fourier_transf){

    // Apply inverse Fourier to device pointer and copy back to host
    cufftHandle handler_fft_inv;
    CUFFT_CHECK(cufftPlan1d(&handler_fft_inv, fft_ptr_length, CUFFT_C2R, 1));
    CUFFT_CHECK(cufftExecC2R(handler_fft_inv, fourier_transf, dev_signal));
    CUFFT_CHECK(cufftDestroy(handler_fft_inv));
}

static void applyLowPassFilter(cufftComplex *fft, const size_t length,
                               const int cutoff_freq = 50) {
  const size_t max_threads = 1024;
  const size_t workload_per_thread = 2;

  const size_t block_size = divUp<size_t>(max_threads, workload_per_thread);
  const size_t grid_size = divUp<size_t>(length, block_size);

  cudaStream_t kernel_strm;
  CUDA_CHECK(cudaStreamCreate(&kernel_strm));

  lowPassKernel<<<grid_size, block_size, 0, kernel_strm>>>(fft, cutoff_freq,
                                                           length);

  CUDA_CHECK(cudaStreamSynchronize(kernel_strm));
  CUDA_CHECK(cudaPeekAtLastError());
  CUDA_CHECK(cudaStreamDestroy(kernel_strm));
}

void gpuDenoiseData(float *audio_data, const int sample_rate, const size_t signal_length) {

  assert(signal_length > 0);

  // Upload host data to gpu
  cudaStream_t copy_strm;
  CudaUniquePtr<float> dev_audio_data(signal_length);
  CUDA_CHECK(cudaStreamCreate(&copy_strm));
  CUDA_CHECK(cudaMemcpyAsync(dev_audio_data.get(), audio_data,
                             signal_length * sizeof(float),
                             cudaMemcpyHostToDevice, copy_strm));

  // Calculate FFT on device audio data
  const size_t fft_ptr_length = divUp<unsigned int>(signal_length, 2);

  CudaUniquePtr<cufftComplex> dev_fourier;
  dev_fourier.make_unique(fft_ptr_length);
  if(copy_strm){
      CUDA_CHECK(cudaStreamSynchronize(copy_strm));
  }

  const int cutoff_freq = calculateCutoffFrequency(sample_rate, signal_length);

  cudaFftSingleDim(signal_length, dev_audio_data.get(), dev_fourier.get());
  applyLowPassFilter(dev_fourier.get(), fft_ptr_length, cutoff_freq);
  cudaFftSingleDimInverse(fft_ptr_length, dev_audio_data.get(), dev_fourier.get());

  CUDA_CHECK(cudaMemcpy(audio_data, dev_audio_data.get(),
                        signal_length, cudaMemcpyDeviceToHost));

}

} // namespace gpudenoise
