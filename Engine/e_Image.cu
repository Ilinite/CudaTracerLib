#include "e_Image.h"
#include <cuda_surface_types.h>

void e_Image::AddSample(float sx, float sy, const Spectrum &_L)
{
	if (_L.isNaN() || !_L.isValid())
		return;
	Spectrum L = _L;
	L.clampNegative();
	int x = math::Floor2Int(sx), y = math::Floor2Int(sy);
	if (x < 0 || x >= xResolution || y < 0 || y >= yResolution || L.isNaN() || !L.isValid())
		return;
	float rgb[3];
	L.toLinearRGB(rgb[0], rgb[1], rgb[2]);
	Pixel* pixel = getPixel(y * xResolution + x);
#ifdef ISCUDA
	for(int i = 0; i < 3; i++)
		atomicAdd(pixel->rgb + i, rgb[i]);
	atomicAdd(&pixel->weightSum, 1.0f);
#else
	for(int i = 0; i < 3; i++)
		pixel->rgb[i] += rgb[i];
	pixel->weightSum += 1.0f;
#endif
}

void e_Image::Splat(float sx, float sy, const Spectrum &_L)
{
	if (_L.isNaN() || !_L.isValid())
		return;
	Spectrum L = _L;
	L.clampNegative();
	int x = math::Floor2Int(sx), y = math::Floor2Int(sy);
	if (x < 0 || x >= xResolution || y < 0 || y >= yResolution)
		return;
	Pixel* pixel = getPixel(y * xResolution + x);
	float rgb[3];
	L.toLinearRGB(rgb[0], rgb[1], rgb[2]);
#ifdef ISCUDA
	for(int i = 0; i < 3; i++)
		atomicAdd(pixel->rgbSplat + i, rgb[i]);
#else
	for(int i = 0; i < 3; i++)
		pixel->rgbSplat[i] += rgb[i];
#endif
}

CUDA_FUNC_IN unsigned int FloatToUInt(float f)
{
	//int mask = -int(*(unsigned int*)&f >> 31) | 0x80000000;
	//return (*(unsigned int*)&f) ^ mask;
	return unsigned int(math::clamp(f, 0.0f, 100.0f) * 1000000);
}

CUDA_FUNC_IN float UIntToFloat(unsigned int f)
{
	//unsigned int mask = ((f >> 31) - 1) | 0x80000000, q = f ^ mask;
	//return *(float*)&q;
	return float(f) / 1000000.0f;
}

///Reinhard Tone Mapping Operator
CUDA_ALIGN(16) CUDA_DEVICE float g_LogLum;
CUDA_ALIGN(16) CUDA_DEVICE unsigned int g_MaxLum;
CUDA_ALIGN(16) CUDA_SHARED float s_LogLum;
CUDA_ALIGN(16) CUDA_SHARED unsigned int s_MaxLum;
CUDA_GLOBAL void rtm_SumLogLum(e_Image::Pixel* P, unsigned int w, unsigned int h, float splatScale)
{
	int x = blockIdx.x * blockDim.x + threadIdx.x, y = blockIdx.y * blockDim.y + threadIdx.y;
	if(x < w && y < h)
	{
		s_LogLum = s_MaxLum = 0;
		__syncthreads();
		Spectrum L_w = P[y * w + x].toSpectrum(splatScale);
		float f2 = L_w.getLuminance();
		f2 = math::clamp(f2, 0.0f, 100.0f);
		float logLum = logf(0.0001f + f2);
		atomicAdd(&g_LogLum, logLum);
		atomicMax(&g_MaxLum, FloatToUInt(f2));
		__syncthreads();
		if(!threadIdx.x && !threadIdx.y)
		{
			atomicAdd(&g_LogLum, s_LogLum);
			atomicMax(&g_MaxLum, s_MaxLum);
		}
	}
}

struct memTarget
{
	RGBCOL* viewTarget;
	int w, h;

	CUDA_FUNC_IN  void operator()(int x, int y, RGBCOL c)
	{
		viewTarget[y * w + x] = c;
	}
};

struct texTarget
{
	cudaSurfaceObject_t viewCudaSurfaceObject;
	int w, h;

	CUDA_ONLY_FUNC void operator()(int x, int y, RGBCOL c)
	{
		surf2Dwrite(c, viewCudaSurfaceObject, x * 4, y);
	}
};

void e_Image::SetSample(int x, int y, RGBCOL c)
{
	if(outState == 1)
#ifdef ISCUDA
		surf2Dwrite(c, viewCudaSurfaceObject, x * 4, y);
#else
		;
#endif
	else viewTarget[y * xResolution + x] = c;
}

CUDA_FUNC_IN Spectrum evalFilter(e_KernelFilter filter, e_Image::Pixel* P, float splatScale, unsigned int _x, unsigned int _y, unsigned int w, unsigned int h)
{
	//return P[_y * w + _x].toSpectrum(splatScale);
	float dimageX = _x - 0.5f;
	float dimageY = _y - 0.5f;
	int x0 = math::Ceil2Int(dimageX - filter.As<e_KernelFilterBase>()->xWidth);
	int x1 = math::Floor2Int(dimageX + filter.As<e_KernelFilterBase>()->xWidth);
	int y0 = math::Ceil2Int(dimageY - filter.As<e_KernelFilterBase>()->yWidth);
	int y1 = math::Floor2Int(dimageY + filter.As<e_KernelFilterBase>()->yWidth);
	x0 = max(x0, 0);
	x1 = min(x1, 0 + int(w) - 1);
	y0 = max(y0, 0);
	y1 = min(y1, 0 + int(h) - 1);
	if ((x1 - x0) < 0 || (y1 - y0) < 0)
		return Spectrum(0.0f);
	Spectrum acc(0.0f);
	float accFilter = 0;
	for (int y = y0; y <= y1; ++y)
	{
		for (int x = x0; x <= x1; ++x)
		{
			float filterWt = filter.Evaluate(fabsf(x - dimageX), fabsf(y - dimageY));
			acc += P[y * w + x].toSpectrum(splatScale).saturate() * filterWt;
			accFilter += filterWt;
		}
	}
	return acc / accFilter;
}

CUDA_FUNC_IN RGBCOL gammaCorrecture(const Spectrum& c)
{
	Spectrum c2;
	c.toSRGB(c2[0], c2[1], c2[2]);
	return c2.toRGBCOL();
}

template<typename TARGET> CUDA_GLOBAL void rtm_Scale(e_Image::Pixel* P, TARGET T, unsigned int w, unsigned int h, float splatScale, float L_w, float alpha, float L_white2, e_KernelFilter filter)
{
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if(x < w && y < h)
	{
		Vec3f yxy;
		evalFilter(filter, P, splatScale, x, y, w, h).toYxy(yxy.x, yxy.y, yxy.z);
		if (yxy.x < 1e-3f)
			return;
		float L = alpha / L_w * yxy.x;
		float L_d = (L * (1.0f + L / L_white2)) / (1.0f + L);
		yxy.x = L_d;
		Spectrum c;
		c.fromYxy(yxy.x, yxy.y, yxy.z);	
		T(x, y, gammaCorrecture(c));
	}
}

template<typename TARGET> CUDA_GLOBAL void rtm_Copy(e_Image::Pixel* P, TARGET T, unsigned int w, unsigned int h, float splatScale, e_KernelFilter filter)
{
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if(x < w && y < h)
	{
		Spectrum c = evalFilter(filter, P, splatScale, x, y, w, h);
		T(x, y, gammaCorrecture(c));
	}
}

void e_Image::InternalUpdateDisplay()
{
	if(outState > 2)
		return;
	if(usedHostPixels)
	{
		cudaMemcpy(cudaPixels, hostPixels, sizeof(Pixel) * xResolution * yResolution, cudaMemcpyHostToDevice);
	}
	memTarget T1;
	texTarget T2;
	T1.w = T2.w = xResolution;
	T1.h = T2.h = yResolution;
	T1.viewTarget = viewTarget;
	T2.viewCudaSurfaceObject = viewCudaSurfaceObject;
	int block = 32;
	if(drawStyle == ImageDrawType::HDR)
	{
		CUDA_ALIGN(16) float Lum_avg = 0;
		unsigned int val = FloatToUInt(0);
		cudaError_t r = cudaMemcpyToSymbol(g_LogLum, &Lum_avg, sizeof(Lum_avg));
		r = cudaMemcpyToSymbol(g_MaxLum, &val, sizeof(unsigned int));
		rtm_SumLogLum << <dim3(xResolution / 32 + 1, yResolution / 32 + 1), dim3(32, 32) >> >(cudaPixels, xResolution, yResolution, lastSplatVal);
		r = cudaThreadSynchronize();
		r = cudaMemcpyFromSymbol(&Lum_avg, g_LogLum, sizeof(Lum_avg));
		unsigned int mLum;
		r = cudaMemcpyFromSymbol(&mLum, g_MaxLum, sizeof(unsigned int));
		float maxLum = UIntToFloat(mLum);
		float L_w = exp(Lum_avg / float(xResolution * yResolution));
		//float middleGrey = 1.03f - 2.0f / (2.0f + log10(L_w + 1.0f));
		float alpha = 0.18, lumWhite2 = max(maxLum * maxLum, 0.1f);
		if(outState == 1)
			rtm_Scale << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T2, xResolution, yResolution, lastSplatVal, L_w, alpha, lumWhite2, filter);
		else rtm_Scale << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T1, xResolution, yResolution, lastSplatVal, L_w, alpha, lumWhite2, filter);
	}
	else
	{
		if(outState == 1)
			rtm_Copy << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T2, xResolution, yResolution, lastSplatVal, filter);
		else rtm_Copy << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T1, xResolution, yResolution, lastSplatVal, filter);
	}
}

template<typename TARGET> CUDA_GLOBAL void rtm_Copy(e_Image::Pixel* A, e_Image::Pixel* B, TARGET T, unsigned int w, unsigned int h, float splatScaleA, float splatScaleB, e_KernelFilter filterA, e_KernelFilter filterB, float scale)
{
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if (x < w && y < h)
	{
		Spectrum aColor = A[y * w + x].toSpectrum(splatScaleA);// evalFilter(filterA, A, splatScaleA, x, y, w, h);
		Spectrum bColor = B[y * w + x].toSpectrum(splatScaleB);//evalFilter(filterB, B, splatScaleB, x, y, w, h);
		Spectrum c = (aColor - bColor).abs() * scale;
		T(x, y, c.toRGBCOL());
	}
}

void e_Image::ComputeDiff(const e_Image& A, const e_Image& B, e_Image& dest, float scale)
{
	memTarget T1;
	texTarget T2;
	T1.w = T2.w = dest.xResolution;
	T1.h = T2.h = dest.yResolution;
	T1.viewTarget = dest.viewTarget;
	T2.viewCudaSurfaceObject = dest.viewCudaSurfaceObject;
	int block = 32;
	unsigned int w = dest.xResolution, h = dest.yResolution;
	if (dest.outState == 1)
		rtm_Copy << <dim3(w / block + 1, h / block + 1), dim3(block, block) >> >(A.cudaPixels, B.cudaPixels, T2, w, h, A.lastSplatVal, B.lastSplatVal, A.filter, B.filter, scale);
	else rtm_Copy << <dim3(w / block + 1, h / block + 1), dim3(block, block) >> >(A.cudaPixels, B.cudaPixels, T1, w, h, A.lastSplatVal, B.lastSplatVal, A.filter, B.filter, scale);
}

void e_Image::Clear()
{
	usedHostPixels = false;
	Platform::SetMemory(hostPixels, sizeof(Pixel) * xResolution * yResolution);
	cudaMemset(cudaPixels, 0, sizeof(Pixel) * xResolution * yResolution);
	if(outState == 2)
		cudaMemset(viewTarget, 0, sizeof(RGBCOL) * xResolution * yResolution);
	else if(outState == 1)
		cudaMemcpyToArray(viewCudaArray, 0, 0, viewTarget, sizeof(RGBCOL) * xResolution * yResolution, cudaMemcpyDeviceToDevice);
}

template<typename TARGET> CUDA_GLOBAL void rtm_NumSamples(e_Image::Pixel* P, TARGET T, unsigned int w, unsigned int h, float numPasses)
{
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if (x < w && y < h)
	{
		Spectrum c = P[y * w + x].weightSum / numPasses;
		T(x, y, c.toRGBCOL());
	}
}

void e_Image::DrawSamplePlacement(int numPasses)
{
	int block = 32;
	memTarget T1;
	texTarget T2;
	T1.w = T2.w = xResolution;
	T1.h = T2.h = yResolution;
	T1.viewTarget = viewTarget;
	T2.viewCudaSurfaceObject = viewCudaSurfaceObject;
	if (outState == 1)
		rtm_NumSamples << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T2, xResolution, yResolution, numPasses);
	else rtm_NumSamples << <dim3(xResolution / block + 1, yResolution / block + 1), dim3(block, block) >> >(cudaPixels, T1, xResolution, yResolution, numPasses);
	disableUpdate();
}