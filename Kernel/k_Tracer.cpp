#include <StdAfx.h>
#include "k_Tracer.h"
#include "k_TraceHelper.h"

CudaRNGBuffer k_TracerBase::g_sRngs;
static bool initrng = false;

void k_TracerBase::InitRngs(unsigned int N)
{
	if(!initrng)
	{
		initrng = 1;
		g_sRngs = CudaRNGBuffer(N);
	}
}

k_TracerBase::k_TracerBase()
	: m_pScene(0), m_pBlockSampler(0)
{
	InitRngs(1024 * 768);
	cudaEventCreate(&start);
	cudaEventCreate(&stop);
}