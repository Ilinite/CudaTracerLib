#pragma once

#include "TraceHelper.h"
#include "BlockSampler/IBlockSampler_device.h"
#include "BlockSampler/IBlockSampler.h"
#include <Engine/Image.h>
#include <Engine/Material.h>
#include "TracerSettings.h"

namespace CudaTracerLib {

class DynamicScene;

struct DeviceDepthImage
{
	float* m_pData;
	int w, h;
	CUDA_FUNC_IN void Store(int x, int y, float d)
	{
		m_pData[w * y + x] = NormalizeDepthD3D(d);
	}
	CUDA_FUNC_IN static float NormalizeDepthD3D(float d)
	{
		Vec2f nf = g_SceneData.m_Camera.As()->m_fNearFarDepths;
		float z = math::clamp(d, nf.x, nf.y);
		return (nf.y / (nf.y - nf.x) * z - nf.y * nf.x / (nf.y - nf.x)) / z;
	}
};

class IDepthTracer
{
	template<bool B> friend class Tracer;
	bool hasImage;
	DeviceDepthImage img;
protected:
	IDepthTracer()
		: hasImage(false)
	{

	}
public:
	virtual ~IDepthTracer()
	{

	}
	virtual void setDepthBuffer(const DeviceDepthImage& img)
	{
		hasImage = true;
		this->img = img;
	}
	bool hasDepthBuffer() const { return hasImage; }
	const DeviceDepthImage& getDeviceDepthBuffer() const { return img; }
};

#define SSGT(X) X(Independent) X(Stratified) X(LowDiscrepency) X(Sobol)
ENUMIZE(SamplingSequenceGeneratorTypes, SSGT)
#undef SSGT
void UpdateSamplingSequenceGenerator(SamplingSequenceGeneratorTypes type, ISamplingSequenceGenerator*& gen);

class TracerBase
{
public:
	CTL_EXPORT static AABB GetEyeHitPointBox(DynamicScene* s, bool recursive);
	CTL_EXPORT static float GetLightVisibility(DynamicScene* s, int recursion_depth);
	CTL_EXPORT static TraceResult TraceSingleRay(Ray r, DynamicScene* s);
	CTL_EXPORT static void RenderDepth(DeviceDepthImage dImg, DynamicScene* s);

	PARAMETER_KEY(SamplingSequenceGeneratorTypes, SamplingSequenceType)

	CUDA_DEVICE static Vec2i getPixelPos(unsigned int xoff, unsigned int yoff)
	{
#ifdef ISCUDA
		unsigned int x = xoff + blockIdx.x * BLOCK_SAMPLER_ThreadsPerBlock.x + threadIdx.x;
		unsigned int y = yoff + blockIdx.y * BLOCK_SAMPLER_ThreadsPerBlock.y + threadIdx.y;
		return Vec2i(x, y);
#else
		return Vec2i(xoff, yoff);
#endif
	}

	CTL_EXPORT TracerBase();
	CTL_EXPORT virtual ~TracerBase();
	virtual void InitializeScene(DynamicScene* a_Scene)
	{
		m_pScene = a_Scene;
	}
	virtual void Resize(unsigned int _w, unsigned int _h) = 0;
	virtual void DoPass(Image* I, bool a_NewTrace) = 0;
	virtual void Debug(Image* I, const Vec2i& pixel)
	{
		UpdateKernel(m_pScene, m_pSamplingSequenceGenerator, &m_uPassesDone);
		UpdateSamplerData(1);
		DebugInternal(I, pixel);
	}
	virtual void PrintStatus(std::vector<std::string>& a_Buf) const
	{

	}
	virtual bool isMultiPass() const = 0;
	virtual unsigned int getNumPassesDone() const
	{
		return m_uPassesDone;
	}
	virtual unsigned int getRaysInLastPass() const
	{
		return m_uLastNumRaysTraced;
	}
	virtual float getLastTimeSpentRenderingSec() const
	{
		return m_fLastRuntime;
	}
	virtual unsigned int getAccRays() const
	{
		return m_uAccNumRaysTraced;
	}
	virtual float getAccTimeSpentRenderingSec() const
	{
		return m_fAccRuntime;
	}
	TracerParameterCollection& getParameters() { return m_sParameters; }
	virtual void setNumSequences() const
	{
		setNumSequences(w * h);
	}
	virtual void setNumSequences(unsigned int n) const
	{
		UpdateSamplerData(n);
	}
	virtual float getSplatScale() const = 0;
	virtual IBlockSampler* getBlockSampler() { return m_pBlockSampler; }
	virtual void setBlockSampler(IBlockSampler* b) { m_pBlockSampler = b; }
protected:
	float m_fLastRuntime;
	unsigned int m_uLastNumRaysTraced;
	float m_fAccRuntime;
	unsigned int m_uAccNumRaysTraced;
	unsigned int m_uPassesDone;
	unsigned int w, h;
	DynamicScene* m_pScene;
	cudaEvent_t start, stop;
	IBlockSampler* m_pBlockSampler;
	TracerParameterCollection m_sParameters;
	ISamplingSequenceGenerator* m_pSamplingSequenceGenerator;
	virtual void DebugInternal(Image* I, const Vec2i& pixel)
	{

	}
};

template<bool PROGRESSIVE> class Tracer : public TracerBase
{
public:
	virtual void Resize(unsigned int _w, unsigned int _h)
	{
		w = _w;
		h = _h;
		if (PROGRESSIVE)
		{
			auto oldSampler = m_pBlockSampler;
			m_pBlockSampler = oldSampler->CreateForSize(_w, _h);
			oldSampler->Free();
			delete oldSampler;
		}
	}
	virtual void DoPass(Image* I, bool a_NewTrace)
	{
		ThrowCudaErrors(cudaEventRecord(start, 0));
		if (a_NewTrace || !PROGRESSIVE)
		{
			m_uPassesDone = 0;
			m_uAccNumRaysTraced = 0;
			m_fAccRuntime = 0;
			I->Clear();
			if (PROGRESSIVE)
				m_pBlockSampler->StartNewRendering(m_pScene, I);
			StartNewTrace(I);
		}
		UpdateSamplingSequenceGenerator(m_sParameters.getValue(KEY_SamplingSequenceType()), m_pSamplingSequenceGenerator);
		UpdateKernel(m_pScene, m_pSamplingSequenceGenerator, &m_uPassesDone);
		k_setNumRaysTraced(0);
		m_uPassesDone++;
		DoRender(I);
		if (PROGRESSIVE)
			m_pBlockSampler->AddPass(I, this);
		ThrowCudaErrors(cudaEventRecord(stop, 0));
		ThrowCudaErrors(cudaEventSynchronize(stop));
		if (start != stop)
			ThrowCudaErrors(cudaEventElapsedTime(&m_fLastRuntime, start, stop));
		else m_fLastRuntime = 0;
		m_fLastRuntime /= 1000.0f;
		m_uLastNumRaysTraced = k_getNumRaysTraced();
		m_fAccRuntime += m_fLastRuntime;
		m_uAccNumRaysTraced += m_uLastNumRaysTraced;
	}
	virtual bool isMultiPass() const
	{
		return PROGRESSIVE;
	}
	virtual float getSplatScale() const
	{
		if (PROGRESSIVE)
			return 1.0f / float(m_uPassesDone);
		else return 0;
	}
protected:
	virtual void RenderBlock(Image* I, int x, int y, int blockW, int blockH)
	{

	}
	virtual void DoRender(Image* I)
	{
		/*
		xxxxxxxx
		x      x	Warp := 8x4
		x      x
		xxxxxxxx

		WW
		WW	Block := 16x8

		BBBB
		BBBB
		BBBB
		BBBB	Block
		BBBB
		BBBB
		BBBB
		BBBB

		*/
		m_pBlockSampler->IterateBlocks([&](unsigned int block_idx, int x, int y, int bw, int bh)
		{
			RenderBlock(I, x, y, bw, bh);
		});
	}
	virtual void StartNewTrace(Image* I)
	{

	}
};

}