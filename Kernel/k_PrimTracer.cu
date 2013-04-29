#include "k_PrimTracer.h"
#include "k_TraceHelper.h"
#include "..\Base\CudaRandom.h"
#include "..\Engine\e_Terrain.h"

texture<int4, 1> t_Terrain;
texture<float2, 1> t_TerrainCache;
#define BIT_MASK(a, b) (((unsigned) -1 >> (31 - (b))) & ~((1U << (a)) - 1))
#define POS_LEN 14
#define DEP_LEN 4
#define USE_QUAD

/*
	float3 n = make_float3(0,0,0);
	if(TraverseTerrain3(g_SceneData.m_sTerrain, dir, ori, 0, r.m_fDist, &n))
	{
		n = normalize(n);
		//c = n;
		c = make_float3((dot(dir, n)));
	}*/

//ballot

			/*
						signed char o01 = l.y & 255, o02 = (l.y >> 8) & 255,
						o10 = (l.y >> 16) & 255, o11 = l.y >> 24, o12 = l.z & 255,
						o20 = (l.z >> 8) & 255, o21 = (l.z >> 16) & 255, o22 = l.z >> 24;
			float H00 = int_as_float(l.x),		 H01 = H00 + (float)o01 * 8.0f, H02 = H01 + (float)o02 * 8.0f,
				  H10 = H00 + (float)o10 * 8.0f, H11 = H10 + (float)o11 * 8.0f, H12 = H11 + (float)o12 * 8.0f,
				  H20 = H10 + (float)o20 * 8.0f, H21 = H20 + (float)o21 * 8.0f, H22 = H21 + (float)o22 * 8.0f;
			*/

__device__ __inline__ float2 calc_BASE(int b, float2& p0, float2& p1, float3& idir, float3& ori, float mi, float ma)
{
	//perfect place for : vmax2, vmin2
	float2 yd = make_float2(__half2float(b & 0xffff), __half2float(b >> 16)); yd.y += yd.x;
	float tx1 = (p0.x - ori.x) * idir.x;
	float tx2 = (p1.x - ori.x) * idir.x;
	//float tmin = MIN(tx1, tx2);
    //float tmax = MAX(tx1, tx2);
	float ty1 = (yd.x - ori.y) * idir.y;
	float ty2 = (yd.y - ori.y) * idir.y;
	//tmin = MAX(tmin, MIN(ty1, ty2));
    //tmax = MIN(tmax, MAX(ty1, ty2));
	float tz1 = (p0.y - ori.z) * idir.z;
	float tz2 = (p1.y - ori.z) * idir.z;
	//tmin = MAX(tmin, MIN(tz1, tz2));
    //tmax = MIN(tmax, MAX(tz1, tz2));
	float tmin = spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, mi);
	float tmax = spanEndKepler  (tx1, tx2, ty1, ty2, tz1, tz2, ma);
	return make_float2(tmin, tmax);
}

__device__ __inline__ bool calc(int b, float2& p0, float2& p1, float3& idir, float3& ori, float mi, float ma)
{
	float2 f = calc_BASE(b, p0, p1, idir, ori, mi, ma);
	return f.y > f.x && f.y > 0;
}

__device__ __inline__ void calc(int b, float2& p0, float2& p1, float3& idir, float3& ori, float mi, float ma, int& c, unsigned int* T, unsigned char off0, unsigned char off1)
{
	float2 f = calc_BASE(b, p0, p1, idir, ori, mi, ma);
	if(f.y > f.x && f.y > 0)
		T[c++] = __float2half_rn(f.x) << 16 | off0 << 1 | off1;
}

__device__ __inline__ bool calc( const float2& p0, const float2& p1, const float H0, const float H1, const float H2, const float H3, const float3 dir, const float3 ori, const float mi, float& ma, float2 sdxy, float3* NOR)
{
	float3 q = make_float3(ori.x - p0.x, ori.y - H0, ori.z - p0.y);
	float2 dy = make_float2(H1 - H0, H2 - H0);
	float la = (q.y - dy.x * q.x / sdxy.x - dy.y * q.z / sdxy.y) / (-dir.y + dir.x * dy.x / sdxy.x + dir.z * dy.y / sdxy.y);
	float ny = (q.x + la * dir.x) / sdxy.x, al = (q.z + la * dir.z) / sdxy.y;
	if(la >= 0 && la < ma && ny >= 0 && ny <= 1 && al >= 0 && al <= 1 && ny <= (1 - al))
	{
		ma = la;
		*NOR = cross(make_float3(sdxy.x,dy.x,0), make_float3(0,dy.y,sdxy.y));
		return true;
	}
	else
	{
		sdxy *= -1.0f;
		q = make_float3(ori.x - p1.x, ori.y - H3, ori.z - p1.y);
		dy = make_float2(H2 - H3, H1 - H3);
		la = (q.y - dy.x * q.x / sdxy.x - dy.y * q.z / sdxy.y) / (-dir.y + dir.x * dy.x / sdxy.x + dir.z * dy.y / sdxy.y);
		ny = (q.x + la * dir.x) / sdxy.x;
		al = (q.z + la * dir.z) / sdxy.y;
		if(la >= 0 && la < ma && ny >= 0 && ny <= 1 && al >= 0 && al <= 1 && ny <= (1 - al))
		{
			ma = la;
			*NOR = cross(make_float3(sdxy.x,dy.x,0), make_float3(0,dy.y,sdxy.y));
			return true;
		}
		return false;
	}
}

__device__ __inline__ bool TraverseTerrain2(e_KernelTerrainData& T, float3 dir, float3 ori, float mi, float& ma, float3* NOR)
{
	ori -= make_float3(T.m_sMin.x, 0, T.m_sMin.z);
	bool hitF = false;
	float3 idir = make_float3(1) / dir;
	unsigned int stack[32];
	int at = 1;
	stack[0] = 0;
	float2 sdxy = T.getsdxy();
	unsigned int stack2[32];
	int at2 = 0;
	while(at)
	{
		unsigned int val = stack[--at];
		unsigned int d = (val >> (2 * POS_LEN)) & 31, y = (val >> POS_LEN) & 16383, x = val & 16383;
		while(true)
		{
			int index = calcIndex(x, y, d, T.m_uDepth);
			int4 l = tex1Dfetch(t_Terrain, index);
			int of = calcBoxSize(d + 1, T.m_uDepth);
			float2 dxy = (float)of * sdxy, pxy = make_float2(sdxy.x * (float)x, sdxy.y * (float)y);
			float2 p00 = pxy, p10 = p00 + make_float2(dxy.x, 0), p01 = p00 + make_float2(0, dxy.y), p11 = p00 + dxy,
				   p21 = p11 + make_float2(dxy.x, 0), p22 = p11 + dxy, p12 = p11 + make_float2(0, dxy.y);
			if(d + 1 == T.m_uDepth - 1)
			{
				if(calc(l.x, p00, p11, idir, ori, mi, ma))
					stack2[at2++] = (x << 16) | y;
				if(calc(l.y, p10, p21, idir, ori, mi, ma))
					stack2[at2++] = ((x + of) << 16) | y;
				if(calc(l.w, p11, p22, idir, ori, mi, ma))
					stack2[at2++] = ((x + of) << 16) | (y + of);
				if(calc(l.z, p01, p12, idir, ori, mi, ma))
					stack2[at2++] = (x << 16) | (y + of);
				break;
			}
			else
			{
				bool b0 = calc(l.x, p00, p11, idir, ori, mi, ma), b1 = calc(l.y, p10, p21, idir, ori, mi, ma), b2 = calc(l.w, p11, p22, idir, ori, mi, ma), b3 = calc(l.z, p01, p12, idir, ori, mi, ma);
				int x2 = x, y2 = y;
				d++;
				int i = 0;
				if(b0)
					i = 1;
				if(b1)
					if(i)
						stack[at++] = (d << (2 * POS_LEN)) | (y2 << POS_LEN) | (x2 + of);
					else
					{
						x += of;
						i = 1;
					}
				if(b2)
					if(i)
						stack[at++] = (d << (2 * POS_LEN)) | ((y2 + of) << POS_LEN) | (x2 + of);
					else
					{
						x += of;
						y += of;
						i = 1;
					}
				if(b3)
					if(i)
						stack[at++] = (d << (2 * POS_LEN)) | ((y2 + of) << POS_LEN) | x2;
					else
					{
						y += of;
						i = 1;
					}
				if(!i)
					break;
			}
		}
		while(at2)//(!at && at2) || __ballot(at2) > 20
		{
			unsigned int val = stack2[--at2];
			unsigned int x = val >> 16, y = val & 0xffff;
			float2 pxy = make_float2(sdxy.x * (float)x, sdxy.y * (float)y);
			float2 p00 = pxy, p10 = p00 + make_float2(sdxy.x, 0), p01 = p00 + make_float2(0, sdxy.y), p11 = p00 + sdxy,
				   p21 = p11 + make_float2(sdxy.x, 0), p22 = p11 + sdxy, p12 = p11 + make_float2(0, sdxy.y);
			int index = calcIndex(x, y, T.m_uDepth - 1, T.m_uDepth);
			int4 l = tex1Dfetch(t_Terrain, index);
			unsigned short o0 = l.y & 0xffff, o1 = l.y >> 16, o2 = l.z & 0xffff, o3 = l.z >> 16;
			unsigned char s0 = l.w & 255, s1 = (l.w >> 8) & 255, s2 = (l.w >> 16) & 255, s3 = (l.w >> 24) & 255;
			float H11 = int_as_float(l.x), H00 = H11 + __half2float(o0), H02 = H11 + __half2float(o1), H20 = H11 + __half2float(o2), H22 = H11 + __half2float(o3),
				  H01 = lerp(H00, H02, float(s0) / 255.0f), H21 = lerp(H20, H22, float(s1) / 255.0f),
				  H10 = lerp(H00, H20, float(s2) / 255.0f), H12 = lerp(H02, H22, float(s3) / 255.0f);
#ifdef USE_QUAD
			hitF |= calc(p00, p11, H00, H01, H10, H11, dir, ori, mi, ma, sdxy, NOR);
			hitF |= calc(p10, p21, H01, H02, H11, H12, dir, ori, mi, ma, sdxy, NOR);
			hitF |= calc(p01, p12, H10, H11, H20, H21, dir, ori, mi, ma, sdxy, NOR);
			hitF |= calc(p11, p22, H11, H12, H21, H22, dir, ori, mi, ma, sdxy, NOR);
#else
			hitF |= calc(p00, p22, H00, H02, H20, H22, dir, ori, mi, ma, sdxy * 2.0f, NOR);
#endif
		}
	}
	return hitF;
}

CUDA_ONLY_FUNC bool rayBoxIntersectionA2(float3& m_Dir, float3& m_Ori, float3* data, float* tMin, float* tMax)
{
	float tx1 = (data[0].x - m_Ori.x) / m_Dir.x;
	float tx2 = (data[1].x - m_Ori.x) / m_Dir.x;
	float ty1 = (data[0].y - m_Ori.y) / m_Dir.y;
	float ty2 = (data[1].y - m_Ori.y) / m_Dir.y;
	float tz1 = (data[0].z - m_Ori.z) / m_Dir.z;
	float tz2 = (data[1].z - m_Ori.z) / m_Dir.z;
	*tMin = spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, 0);
	*tMax = spanEndKepler  (tx1, tx2, ty1, ty2, tz1, tz2, FLT_MAX);
	return *tMax > *tMin && *tMax > 0.0f;
}

__device__ __inline__ float __divFull(float a, float b)
{
#ifdef __CUDA_FTZ
#undef __CUDA_FTZ
	return __fdividef(a, b);
#define __CUDA_FTZ
#else
	return __fdividef(a, b);
#endif
}

//unsigned int index = calcIndex(xy.x, xy.y, T.m_uDepth);
		//float t = -ori.y / dir.y;
		//float3 h = ori + dir * t;
		//if(p00.x <= h.x && p22.x >= h.x && p00.y <= h.z && p22.y >= h.z)
		//	hitF = true;
		//if(hitF)
		//	*NOR = make_float3((int)xy.x % 4, 0, (int)xy.y % 4)/2;

		//unsigned int index = calcIndex_Direct((int)xy.x, (int)xy.y, iLvl);
		//int4 l = tex1Dfetch(t_Terrain, index);
		//float2 yd1 = make_float2(__half2float(l.x & 0xffff), __half2float(l.x >> 16)); yd1.y += yd1.x;
		//float2 yd2 = make_float2(__half2float(l.y & 0xffff), __half2float(l.y >> 16)); yd2.y += yd2.x;
		//float2 yd3 = make_float2(__half2float(l.z & 0xffff), __half2float(l.z >> 16)); yd3.y += yd3.x;
		//float2 yd4 = make_float2(__half2float(l.w & 0xffff), __half2float(l.w >> 16)); yd4.y += yd4.x;
		//float2 yd = make_float2(MIN(yd1.x, yd2.x, yd3.x, yd4.x), MAX(yd1.y, yd2.y, yd3.y, yd4.y));
		//yd = make_float2(-FLT_MAX, FLT_MAX);

/*
		float3 p = ori + dir * (mima.x+1);
		float2 xy = floor(make_float2(p.x / sdxy.x, p.z / sdxy.y)/2.0f)*2, pxy = xy * sdxy;
		float2 p00 = pxy, p10 = p00 + make_float2(sdxy.x, 0), p01 = p00 + make_float2(0, sdxy.y), p11 = p00 + sdxy,
			   p21 = p11 + make_float2(sdxy.x, 0), p22 = p11 + sdxy, p12 = p11 + make_float2(0, sdxy.y);
		unsigned int index = calcIndex((int)xy.x, (int)xy.y, T.m_uDepth - 1, T.m_uDepth);
		
		int4 l = tex1Dfetch(t_Terrain, index);
		unsigned short o0 = l.y & 0xffff, o1 = l.y >> 16, o2 = l.z & 0xffff, o3 = l.z >> 16;
		unsigned char s0 = l.w & 255, s1 = (l.w >> 8) & 255, s2 = (l.w >> 16) & 255, s3 = (l.w >> 24) & 255;
		float H11 = int_as_float(l.x), H00 = H11 + __half2float(o0), H02 = H11 + __half2float(o1), H20 = H11 + __half2float(o2), H22 = H11 + __half2float(o3),
			  H01 = lerp(H00, H02, float(s0) / 255.0f), H21 = lerp(H20, H22, float(s1) / 255.0f),
			  H10 = lerp(H00, H20, float(s2) / 255.0f), H12 = lerp(H02, H22, float(s3) / 255.0f);
		//hitF |= calc(p00, p22, H00, H02, H20, H22, dir, ori, mima.x, mima.y, sdxy * 2.0f, NOR);
		hitF |= calc(p00, p11, H00, H01, H10, H11, dir, ori, mima.x, mima.y, sdxy, NOR);
		hitF |= calc(p10, p21, H01, H02, H11, H12, dir, ori, mima.x, mima.y, sdxy, NOR);
		hitF |= calc(p01, p12, H10, H11, H20, H21, dir, ori, mima.x, mima.y, sdxy, NOR);
		hitF |= calc(p11, p22, H11, H12, H21, H22, dir, ori, mima.x, mima.y, sdxy, NOR);

		calc(p00, p22, I, O, mima.x, mima.y);
*/

__device__ __inline__ bool TraverseTerrain3(e_KernelTerrainData& T, float3 dir, float3 ori, float miA, float& maA, float3* NOR)
{
	float2 mima = make_float2(miA, maA);
	if(!rayBoxIntersectionA2(dir, ori, &T.m_sMin, &mima.x, &mima.y))
		return false;
	mima.y += 1;
	ori -= make_float3(T.m_sMin.x, 0, T.m_sMin.z);
	bool hitF = false;
	float3 I;
	const float ooeps = exp2f(-80.0f);
	I.x = 1.0f / (fabsf(dir.x) > ooeps ? dir.x : copysignf(ooeps, dir.x));
	I.y = 1.0f / (fabsf(dir.y) > ooeps ? dir.y : copysignf(ooeps, dir.y));
	I.z = 1.0f / (fabsf(dir.z) > ooeps ? dir.z : copysignf(ooeps, dir.z));
	float3 O = -ori * I;
	float2 sdxy = T.getsdxy();
	float2 uv = make_float2(T.m_sMax.x - T.m_sMin.x, T.m_sMax.z - T.m_sMin.z) / float(pow2(CACHE_LEVEL));
	do
	{
		float3 p = ori + dir * (mima.x+1);
		float2 xy = floor(make_float2(__divFull(p.x, uv.x), __divFull(p.z, uv.y))), pxy = xy * uv;
		float2 p00 = pxy, p22 = p00 + uv;
		float index = xy.y * float(pow2(CACHE_LEVEL)) + xy.x;
		float2 yd = tex1Dfetch(t_TerrainCache, (int)index);

		float tx1 = p00.x * I.x + O.x;
		float tx2 = p22.x * I.x + O.x;
		float ty1 = yd.x *  I.y + O.y;
		float ty2 = yd.y *  I.y + O.y;
		float tz1 = p00.y * I.z + O.z;
		float tz2 = p22.y * I.z + O.z;
		float tmin = spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, mima.x);
		float tmax = spanEndKepler  (tx1, tx2, ty1, ty2, tz1, tz2, mima.y);
		float tmin2 = spanBeginKepler(tx1, tx2, -FLT_MAX, FLT_MAX, tz1, tz2, mima.x);
		float tmax2 = spanEndKepler (tx1, tx2, -FLT_MAX, FLT_MAX, tz1, tz2, mima.y);//assert(tmax2 >= tmax)
		if(tmax2 <= tmin2 || tmax2 < 0)
			break;
		if(tmax > tmin && tmax > 0)
			while(mima.x < tmax)
			{
				float3 p = ori + dir * (mima.x+1);
				float2 xy = floor(make_float2(__divFull(p.x, 2.0f * sdxy.x), __divFull(p.z, 2.0f * sdxy.y))), pxy = xy * sdxy * 2.0f;
				float2 p00 = pxy, p10 = p00 + make_float2(sdxy.x, 0), p01 = p00 + make_float2(0, sdxy.y), p11 = p00 + sdxy,
					   p21 = p11 + make_float2(sdxy.x, 0), p22 = p11 + sdxy, p12 = p11 + make_float2(0, sdxy.y);
				unsigned int index = calcIndex_Direct((int)xy.x, (int)xy.y, T.m_uDepth - 1);
		
				int4 l = tex1Dfetch(t_Terrain, index);
				unsigned short o0 = l.y & 0xffff, o1 = l.y >> 16, o2 = l.z & 0xffff, o3 = l.z >> 16;
				unsigned char s0 = l.w & 255, s1 = (l.w >> 8) & 255, s2 = (l.w >> 16) & 255, s3 = (l.w >> 24) & 255;
				float H11 = int_as_float(l.x), H00 = H11 + __half2float(o0), H02 = H11 + __half2float(o1), H20 = H11 + __half2float(o2), H22 = H11 + __half2float(o3),
					  H01 = lerp(H00, H02, float(s0) / 255.0f), H21 = lerp(H20, H22, float(s1) / 255.0f),
					  H10 = lerp(H00, H20, float(s2) / 255.0f), H12 = lerp(H02, H22, float(s3) / 255.0f);
				hitF |= calc(p00, p22, H00, H02, H20, H22, dir, ori, mima.x, mima.y, sdxy * 2.0f, NOR);
				//hitF |= calc(p00, p11, H00, H01, H10, H11, dir, ori, mima.x, mima.y, sdxy, NOR);
				//hitF |= calc(p10, p21, H01, H02, H11, H12, dir, ori, mima.x, mima.y, sdxy, NOR);
				//hitF |= calc(p01, p12, H10, H11, H20, H21, dir, ori, mima.x, mima.y, sdxy, NOR);
				//hitF |= calc(p11, p22, H11, H12, H21, H22, dir, ori, mima.x, mima.y, sdxy, NOR);
				float tx1 = p00.x * I.x + O.x;
				float tx2 = p22.x * I.x + O.x;
				float tz1 = p00.y * I.z + O.z;
				float tz2 = p22.y * I.z + O.z;
				float ty1 = -FLT_MAX, ty2 = FLT_MAX;
				float tmini = spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, mima.x);
				float tmaxi = spanEndKepler  (tx1, tx2, ty1, ty2, tz1, tz2, tmax);
				mima.x = (tmaxi > tmini && tmaxi > 0) ? tmaxi : tmax;
			}
		mima.x = tmax2;
	}
	while(mima.x < mima.y);
	return hitF;
}

__device__ float3 trace(Ray& r, CudaRNG& rng)
{
	TraceResult r2;
	r2.Init();
	float3 c = make_float3(1);
	unsigned int depth = 0;
	while(k_TraceRay<true>(r.direction, r.origin, &r2) && depth++ < 5)
	{//return make_float3(r.m_fDist/3);
		if(g_SceneData.m_sVolume.HasVolumes())
			c = c * exp(-g_SceneData.m_sVolume.tau(r, 0, r2.m_fDist));
		float3 wi;
		float pdf;
		e_KernelBSDF bsdf = r2.m_pTri->GetBSDF(r2.m_fUV, r2.m_pNode->getWorldMatrix(), g_SceneData.m_sMatData.Data, r2.m_pNode->m_uMaterialOffset);
		BxDFType sampledType;
		float3 f = bsdf.Sample_f(-r.direction, &wi, BSDFSample(0.64563f, 0.173f, rng.randomFloat()), &pdf, BSDF_ALL, &sampledType);
		f = bsdf.IntegratePdf(f, pdf, -r.direction);
		c = c * f;
		if((sampledType & BSDF_SPECULAR) != BSDF_SPECULAR)
			break;
		r.origin = r(r2.m_fDist);
		r.direction = wi;
		r2.Init();
	}
	c = c * r2.hasHit();
	return c;
}

__global__ void primaryKernel(long long width, long long height, RGBCOL* a_Data)
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
		float3 c = make_float3(0);
		float N = 1;
		for(float f = 0; f < N; f++)
		{
			Ray r = g_CameraData.GenRay(x, y, width, height, rng.randomFloat(), rng.randomFloat());
			c += trace(r, rng);
		}
		c /= N;

		unsigned int cl2 = toABGR(c);
		((unsigned int*)a_Data)[y * width + x] = cl2;
	}
	while(true);
	g_RNGData(rng);
}

__global__ void debugPixe2l(unsigned int width, unsigned int height, int2 p)
{
	Ray r = g_CameraData.GenRay(p.x, p.y, width, height);
	//dir = make_float3(-0.98181188f, 0.18984018f, -0.0024534566f);
	//ori = make_float3(68790.375f, -12297.199f, 57510.383f);
	//ori += make_float3(g_SceneData.m_sTerrain.m_sMin.x, 0, g_SceneData.m_sTerrain.m_sMin.z);
	trace(r, g_RNGData());
}

void k_PrimTracer::DoRender(RGBCOL* a_Buf)
{
	m_sRngs.m_uOffset++;
	k_INITIALIZE(m_pScene->getKernelSceneData());
	k_STARTPASS(m_pScene, m_pCamera, m_sRngs);
	primaryKernel<<< 180, dim3(32, MaxBlockHeight, 1)>>>(w, h, a_Buf);
	cudaError_t r = cudaThreadSynchronize();
}

void k_PrimTracer::Debug(int2 pixel)
{
	m_pScene->UpdateInvalidated();
	e_KernelDynamicScene d2 = m_pScene->getKernelSceneData();
	k_INITIALIZE(d2);
	k_STARTPASS(m_pScene, m_pCamera, m_sRngs);
	cudaChannelFormatDesc cd2 = cudaCreateChannelDesc<int4>();
	size_t offset;
	cudaBindTexture(&offset, &t_Terrain, d2.m_sTerrain.m_pNodes, &cd2, sum_pow4(d2.m_sTerrain.m_uDepth) * sizeof(int4));
	cudaChannelFormatDesc cd3 = cudaCreateChannelDesc<float2>();
	cudaBindTexture(&offset, &t_TerrainCache, d2.m_sTerrain.m_pCacheData, &cd3, pow4(CACHE_LEVEL) * sizeof(CACHE_LEVEL_TYPE));
	debugPixe2l<<<1,1>>>(w,h,pixel);
}