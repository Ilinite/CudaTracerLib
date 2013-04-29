#include "k_PathTracer.h"
#include "k_TraceHelper.h"
#include <time.h>

__device__ float3 radiance(float3& a_Dir, float3& a_Ori, CudaRNG& rnd)
{
	Ray r0 = Ray(a_Ori, a_Dir);
	TraceResult r;
	float3 cl = make_float3(0,0,0);   // accumulated color
	float3 cf = make_float3(1,1,1);  // accumulated reflectance
	int depth = 0;
	while (depth++ < 7)
	{
		r.Init();
		if(!k_TraceRay<true>(r0.direction, r0.origin, &r))
		{
			//cl = cf * make_float3(0.7f);
			break;
		}
		float3 inc;
		float pdf;
		e_KernelBSDF bsdf = r.m_pTri->GetBSDF(r.m_fUV, r.m_pNode->getWorldMatrix(), g_SceneData.m_sMatData.Data, r.m_pNode->m_uMaterialOffset);
		cl += cf * r.m_pTri->Le(r.m_fUV, bsdf.ng, -r0.direction, g_SceneData.m_sMatData.Data, r.m_pNode->m_uMaterialOffset);
		float3 f = bsdf.Sample_f(-r0.direction, &inc, BSDFSample(rnd), &pdf);
		float p = f.x>f.y && f.x>f.z ? f.x : f.y>f.z ? f.y : f.z; 
		if (depth > 5)
			if (rnd.randomFloat() < p)
				f = f / p;
			else break;
		if(!pdf)
			break;
		cf = cf * bsdf.IntegratePdf(f, pdf, inc);
		/*
		float3 x = r0(r.m_fDist), nl = bsdf.ng;
		
		float3 toLight;
		int le = -1;
		for(int i = 0; i < g_SceneData.m_sLightData.UsedCount; i++)
		{
			float3 toLightT = g_SceneData.m_sLightData[i].SampleRandomPoint(rnd) - x;
			float l = length(toLightT), l2 = l / 1200.0f;
			if(rnd.randomFloat() > l2)
			{
				toLight = toLightT / l;
				le = i;
				break;
			}
		}
		if(le != -1)
		{
			float diffuse = MAX(0.0f, dot(toLight, nl));
			TraceResult r2;
			r2.Init();
			float3 p0 = x + nl * 0.01f;
			k_TraceRay<true>(toLight, p0, &r2);
			float d2, d3;
			if(rayBoxIntersectionA(toLight, p0, &g_SceneData.m_sLightData[le].box.minV, &d2, &d3) && r2.m_fDist >= d2)			
				cl += cf * diffuse * g_SceneData.m_sLightData[le].m_cPower;
		}*/

		r0 = Ray(r0(r.m_fDist), inc);
	}
	return cl;
}

__global__ void pathKernel(unsigned int width, unsigned int height, RGBCOL* a_Data, unsigned int a_PassIndex, float4* a_DataTmp)
{
	CudaRNG rng = g_RNGData();
	int rayidx;
	int N = width * height;
	__shared__ volatile int nextRayArray[MaxBlockHeight];
	do
    {
        const int tidx = threadIdx.x;
        volatile int& rayBase = nextRayArray[threadIdx.y];

        const bool          terminated     = 1;//nodeAddr == EntrypointSentinel;
        const unsigned int  maskTerminated = __ballot(terminated);
        const int           numTerminated  = __popc(maskTerminated);
        const int           idxTerminated  = __popc(maskTerminated & ((1u<<tidx)-1));	

        if(terminated)
        {			
            if (idxTerminated == 0)
				rayBase = atomicAdd(&g_NextRayCounter, numTerminated);

            rayidx = rayBase + idxTerminated;
			if (rayidx >= N)
                break;
		}

		unsigned int x = rayidx % width, y = rayidx / width;
		Ray r = g_CameraData.GenRay(x, y, width, height,  rng.randomFloat(), rng.randomFloat());
		
		float3 col = radiance(r.direction, r.origin, rng);
		
		float4* data = a_DataTmp + y * width + x;
		*data += make_float4(col, 0);
		a_Data[y * width + x] = Float3ToCOLORREF(clamp01(!*data / (float)a_PassIndex));
	}
	while(true);
	g_RNGData(rng);
}

__global__ void debugPixel(unsigned int width, unsigned int height, int2 p)
{
	CudaRNG rng = g_RNGData();
	Ray r = g_CameraData.GenRay(p.x, p.y, width, height,  rng.randomFloat(), rng.randomFloat());
		
	radiance(r.direction, r.origin, rng);
}

void k_PathTracer::DoRender(RGBCOL* a_Buf)
{
	k_INITIALIZE(m_pScene->getKernelSceneData());
	k_STARTPASS(m_pScene, m_pCamera, m_sRngs);
	pathKernel<<< 180, dim3(32, MaxBlockHeight, 1)>>>(w, h, a_Buf, m_uPassesDone, m_pTmpData);
	m_uPassesDone++;
}

void k_PathTracer::StartNewTrace(RGBCOL* a_Buf)
{
	cudaMemset(m_pTmpData, 0, w * h * sizeof(float4));
}

void k_PathTracer::Resize(unsigned int _w, unsigned int _h)
{
	k_TracerBase::Resize(_w, _h);
	if(m_pTmpData)
		cudaFree(m_pTmpData);
	cudaMalloc(&m_pTmpData, sizeof(float4) * w * h);
	cudaMemset(m_pTmpData, 0, w * h * sizeof(float4));
}

void k_PathTracer::Debug(int2 pixel)
{
	m_pScene->UpdateInvalidated();
	k_INITIALIZE(m_pScene->getKernelSceneData());
	k_STARTPASS(m_pScene, m_pCamera, m_sRngs);
	debugPixel<<<1,1>>>(w,h,pixel);
}