#pragma once
#include "..\Engine\e_Sensor.h"
#include "..\Engine\e_DynamicScene.h"

enum
{
    MaxBlockHeight      = 6,            // Upper bound for blockDim.y.
    EntrypointSentinel  = 0x76543210,   // Bottom-most stack entry, indicating the end of traversal.
};

extern CUDA_ALIGN(16) CUDA_CONST e_KernelDynamicScene g_SceneDataDevice;
extern CUDA_ALIGN(16) CUDA_DEVICE unsigned int g_RayTracedCounterDevice;
extern CUDA_ALIGN(16) CUDA_CONST CudaRNGBuffer g_RNGDataDevice;

extern CUDA_ALIGN(16) e_KernelDynamicScene g_SceneDataHost;
extern CUDA_ALIGN(16) unsigned int g_RayTracedCounterHost;
extern CUDA_ALIGN(16) CudaRNGBuffer g_RNGDataHost;

#ifdef ISCUDA
#define g_SceneData g_SceneDataDevice
#define g_RayTracedCounter g_RayTracedCounterDevice
#define g_RNGData g_RNGDataDevice
#else
#define g_SceneData g_SceneDataHost
#define g_RayTracedCounter g_RayTracedCounterHost
#define g_RNGData g_RNGDataHost
#endif

#ifdef __CUDACC__
#define k_TracerBase_update_TracedRays { cudaMemcpyFromSymbol(&m_uNumRaysTraced, g_RayTracedCounterDevice, sizeof(unsigned int)); }
#else
#define k_TracerBase_update_TracedRays { m_uNumRaysTraced = g_RayTracedCounterHost; }
#endif

//__device__ __host__ bool k_TraceRayNode(const float3& dir, const float3& ori, TraceResult* a_Result, const e_Node* N, int ln);

__device__ __host__ bool k_TraceRay(const float3& dir, const float3& ori, TraceResult* a_Result);

CUDA_FUNC_IN TraceResult k_TraceRay(const Ray& r)
{
	TraceResult r2;
	r2.Init();
	k_TraceRay(r.direction, r.origin, &r2);
	return r2;
}

void k_INITIALIZE(const e_DynamicScene* a_Scene, const CudaRNGBuffer& a_RngBuf);


struct traversalRay
{
	float4 a;
	float4 b;
};

struct CUDA_ALIGN(16) traversalResult
{
	float dist;
	int nodeIdx;
	int triIdx;
	int bCoords;//half2
	CUDA_FUNC_IN void toResult(TraceResult* tR, e_KernelDynamicScene& g_SceneData)
	{
		tR->m_fDist = dist;
		tR->m_fUV = ((half2*)&bCoords)->ToFloat2();
		tR->m_pNode = g_SceneData.m_sNodeData.Data + nodeIdx;
		tR->m_pTri = g_SceneData.m_sTriData.Data + triIdx;
	}
};

void __internal__IntersectBuffers(int N, traversalRay* a_RayBuffer, traversalResult* a_ResBuffer, bool SKIP_OUTER, bool ANY_HIT);