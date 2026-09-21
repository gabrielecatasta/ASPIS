#ifndef CUSPIS_H
#define CUSPIS_H

#include <cstdio>
#include <cstring>
#include <iostream>
#include <driver_types.h>
#include <cuda_runtime_api.h>
#include <list>
#include <vector>

namespace CUSPIS {

    constexpr int NUM_REPLICAS = 2;
    static_assert(NUM_REPLICAS <= 3 && NUM_REPLICAS >=1, "The number of replicas selected is not supported!");

    enum cuspisRedundancyPolicy {
        cuspisRedundantThreads, // use NUM_REPLICAS times the number of threads
        cuspisRedundantBlocks,  // use NUM_REPLICAS times the number of blocks
        cuspisRedundantKernel   // execute the kernel NUM_REPLICAS times
    };

    class MemAllocation {
        private: 
            size_t size;
            void *data;

        public: 
            MemAllocation(void *data, size_t size) :
                data(data), size(size) {}

            /**
             * Returns the size of the data stored in `ptr` if the pointer is in this memory allocation object, 0 otherwise.
             */
            size_t isInMemAllocation(void *ptr) {
                if (data <= ptr && ptr < (void*)(((char*)(data)) + size)) {
                    return size;
                }
                else {
                    return 0;
                }
            }
    };

    // annotate as "exclude" to prevent double bookkeeping with EDDI
    __attribute__ ((annotate("exclude"))) std::list<MemAllocation> allocations;

    template <typename ... Types>
    class Kernel {
        private:
            int Dg, Db, Ns=0;
            cudaStream_t S=0; 
            void (*kernelFunc)(Types ...args);
            cuspisRedundancyPolicy policy;

            void modify () {
            }

            template <typename T>
            void modify (T **x) {
                for (auto Elem : allocations) {
                    auto size = Elem.isInMemAllocation(*x);
                    if (size) {
                        *x = (T*)(((char*)*x) + size);
                        break;
                    }
                }
            }

            template <typename T, typename... Args>
            void modify (T *x, Args... args) {
                modify(args...);
            }

            template <typename T, typename... Args>
            void modify (T **x, Args... args) {
                for (auto Elem : allocations) {
                    auto size = Elem.isInMemAllocation(*x);
                    if (size) {
                        *x = (T*)(((char*)*x) + size);
                        break;
                    }
                }

                modify(args...);
            }

        public:
            Kernel(int Dg, int Db, void (*kernel)(Types ...args), cuspisRedundancyPolicy policy) :
                Dg(Dg), Db(Db), kernelFunc(kernel), policy(policy) {}

            Kernel(int Dg, int Db, int Ns, void (*kernel)(Types ...args), cuspisRedundancyPolicy policy) :
                Dg(Dg), Db(Db), Ns(Ns), kernelFunc(kernel), policy(policy) {}

            Kernel(int Dg, int Db, int Ns, cudaStream_t S, void (*kernel)(Types ...args), cuspisRedundancyPolicy policy) :
                Dg(Dg), Db(Db), Ns(Ns), S(S), kernelFunc(kernel), policy(policy) {}

            // annotate as "cuspis" to prevent double launch with EDDI
            void __attribute__ ((annotate("cuspis"))) launch(Types ...args) {
                if constexpr (NUM_REPLICAS == 1) {
                    kernelFunc<<<Dg, Db, Ns, S>>>(args...);
                    return;
                }

                else if (policy == cuspisRedundantThreads) {
                    if (Db*NUM_REPLICAS <= 1024) {
                        kernelFunc<<<Dg, Db*NUM_REPLICAS, Ns, S>>>(args...);
                    }
                    else { // fallback to redundant blocks
                        fprintf(stderr, "[CUSPIS] Warning: falling back to redundant block policy! Consider using a different amount of threads...\n");
                        policy = cuspisRedundantBlocks;
                        launch(args...); 
                    }
                }
                else if (policy == cuspisRedundantBlocks) {
                    kernelFunc<<<Dg*NUM_REPLICAS, Db, Ns, S>>>(args...);
                }
                else if (policy == cuspisRedundantKernel) {
                    kernelFunc<<<Dg, Db, Ns, S>>>(args...);
                    modify(&args...);
                    kernelFunc<<<Dg, Db, Ns, S>>>(args...);
                    if constexpr (NUM_REPLICAS == 3) {
                        modify(&args...);
                        kernelFunc<<<Dg, Db, Ns, S>>>(args...);
                    }
                }
            }
    };

    cudaError_t DataCorruption_Handler(void* dst, int index) {
        std::cout << index << "\n";
        fprintf(stderr, "Data corruption detected, aborting.\n");
        exit(-1);
    }

    /** 
     * Wrapper of the cudaMalloc() function. 
     * 
     * Allocates `NUM_REPLICAS` times the size required by the malloc 
     */
    template <class T> cudaError_t __attribute__((annotate("cuspis"))) cuspisMalloc(T **devPtr, size_t size) {
        auto res = cudaMalloc(devPtr, size * NUM_REPLICAS);
        allocations.push_back(MemAllocation(*devPtr, size));
        return res;
    }

    /** 
     * Wrapper of the cudaFree() function. 
     */
    template <class T> cudaError_t __attribute__((annotate("cuspis"))) cuspisFree(T **devPtr) {  
        // TODO fix this garbage below -----------v
        auto i=allocations.begin();
        for (auto Elem : allocations) {
            auto size = Elem.isInMemAllocation(*devPtr);
            if (size) {
                allocations.erase(i);
                break;
            }
            i++;
        }
        return cudaFree(*devPtr);
    }

    /**
     * Wrapper of the cudaMemcpy function, from host to device.
     * 
     * Copies two times the data from the host to the device.
     */
    inline cudaError_t __attribute__((annotate("cuspis"))) cuspisMemcpyToDevice(void *dst, const void *src, size_t count) {
        for (int i=0; i<NUM_REPLICAS; i++) {
            cudaMemcpy((char*)dst + (count*i), src, count, cudaMemcpyHostToDevice);
        }
        return cudaSuccess;
    }

    /**
     * Variant for ASPIS EDDI, verifying the source buffer against its duplicate.
     * `src` and `src_dup` are compared before the copy, so a host-side corruption cannot reach both replicas unnoticed. 
     * The pass rewrites 3-arg calls into this form.
     */
    inline cudaError_t __attribute__((annotate("cuspis_dup_of:cuspisMemcpyToDevice"),
            used)) // guarantee the 4-arg function exists in the module with 'used' 
      cuspisMemcpyToDevice(void *dst, const void *src, const void *src_dup, size_t count) {
        if (src_dup != src && memcmp(src, src_dup, count) != 0) {
            for (size_t i = 0; i < count; i++) {
                if (((const char*)src)[i] != ((const char*)src_dup)[i])
                    return DataCorruption_Handler(dst, i);
            }
        }

        auto ret = cudaMemcpy(dst, src, count, cudaMemcpyHostToDevice);
        if (ret != cudaSuccess)
            return ret;

        if constexpr (NUM_REPLICAS == 2) {
            ret = cudaMemcpy((char*)dst + count, src_dup, count, cudaMemcpyHostToDevice);
            if (ret != cudaSuccess)
                return ret;
        }
        
        return ret;
    }


    /**
     * Wrapper of the cudaMemcpy function, from device to host.
     * 
     * Copies the data from the device to the host.
     */
    inline cudaError_t __attribute__((annotate("cuspis"))) cuspisMemcpyToHost(void *dst, const void *src, size_t count) {
        if constexpr (NUM_REPLICAS == 1)
            return cudaMemcpy(dst, src, count, cudaMemcpyDeviceToHost);

        std::vector<char> dst_cpy(count);

        auto ret = cudaMemcpy(dst, src, count, cudaMemcpyDeviceToHost);
        if (ret != cudaSuccess) {
            return ret;
        }

        ret = cudaMemcpy(dst_cpy.data(), (char*)src + count, count, cudaMemcpyDeviceToHost);
        if (ret != cudaSuccess) {
            return ret;
        }

        if (memcmp(dst, dst_cpy.data(), count) != 0) {
            // find the first mismatch
            for (int i=0; i<count; i++) { 
                if (((char*)(dst))[i] != (dst_cpy)[i]) {
                    if constexpr (NUM_REPLICAS == 2)
                        return DataCorruption_Handler(dst, i);
                    else if constexpr (NUM_REPLICAS == 3) // fai il check anche sulla seconda (opzionale)
                        return cudaMemcpy(dst, ((char*)(src)) + 2*count, count, cudaMemcpyDeviceToHost);
                }
            }
        }

        return ret;

    }

    /**
     * Variant for ASPIS EDDI, filling both the original and duplicated destination buffers.
     * `dst` receives replica 0, `dst_dup` receives replica 1, and the two are compared before returning. 
     * The pass rewrites 3-arg calls into this form.
     */
    inline cudaError_t __attribute__((annotate("cuspis_dup_of:cuspisMemcpyToHost"), 
            used)) // guarantee the 4-arg function exists in the module with 'used' 
      cuspisMemcpyToHost(void *dst, void *dst_dup, const void *src, size_t count) {
        if constexpr (NUM_REPLICAS == 1) {
            auto ret = cudaMemcpy(dst, src, count, cudaMemcpyDeviceToHost);
            if (ret == cudaSuccess && dst_dup != dst)
                memcpy(dst_dup, dst, count);
            return ret;
        }

        auto ret = cudaMemcpy(dst, src, count, cudaMemcpyDeviceToHost);
        if (ret != cudaSuccess)
            return ret;

        ret = cudaMemcpy(dst_dup, (char*)src + count, count, cudaMemcpyDeviceToHost);
        if (ret != cudaSuccess)
            return ret;

        if (memcmp(dst, dst_dup, count) != 0) {
            for (int i = 0; i < count; i++) {
                if (((char*)dst)[i] != ((char*)dst_dup)[i])
                    return DataCorruption_Handler(dst, i);
            }
        }

        return ret;
    }
}

#endif