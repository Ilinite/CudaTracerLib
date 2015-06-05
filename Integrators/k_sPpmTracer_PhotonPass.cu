#include "k_sPpmTracer.h"
#include "..\Kernel\k_TraceHelper.h"
#include "..\Kernel\k_TraceAlgorithms.h"

CUDA_DEVICE k_PhotonMapCollection<true, k_pPpmPhoton> g_Map;

template<bool DIRECT> __global__ void k_PhotonPass()
{ 
	CudaRNG rng = g_RNGData();
	CUDA_SHARED unsigned int local_Counter;
	local_Counter = 0;
	unsigned int local_Todo = PPM_Photons_Per_Thread * blockDim.x * blockDim.y;

	DifferentialGeometry dg;
	BSDFSamplingRecord bRec(dg);
	e_KernelAggregateVolume& V = g_SceneData.m_sVolume;

	while (local_Counter < local_Todo && g_Map.m_uPhotonNumStored < g_Map.m_uPhotonBufferLength)
	{
		Ray r;
		const e_KernelLight* light;
		Vec2f sps = rng.randomFloat2(), sds = rng.randomFloat2();
		Spectrum Le = g_SceneData.sampleEmitterRay(r, light, sps, sds),
				 throughput(1.0f);
		int depth = -1;
		atomicInc(&local_Counter, (unsigned int)-1);
		bool wasStored = false;
		bool delta = false;
		MediumSamplingRecord mRec;
		bool medium = false;
		const e_KernelBSSRDF* bssrdf = 0;

		while (++depth < PPM_MaxRecursion && g_Map.m_uPhotonNumStored < g_Map.m_uPhotonBufferLength && !Le.isZero())
		{
			TraceResult r2 = k_TraceRay(r);
			float minT, maxT;
			if ((!bssrdf && V.HasVolumes() && V.IntersectP(r, 0, r2.m_fDist, &minT, &maxT) && V.sampleDistance(r, 0, r2.m_fDist, rng, mRec))
				|| (bssrdf && sampleDistanceHomogenous(r, 0, r2.m_fDist, rng.randomFloat(), mRec, bssrdf->sig_a, bssrdf->sigp_s)))
			{
				throughput *= mRec.sigmaS * mRec.transmittance / mRec.pdfSuccess;
				wasStored |= storePhoton(mRec.p, throughput * Le, -r.direction, Vec3f(0, 0, 0), PhotonType::pt_Volume, g_Map);
				if (bssrdf)
					r.direction = Warp::squareToUniformSphere(rng.randomFloat2());
				else throughput *= V.Sample(mRec.p, -r.direction, rng, &r.direction);
				r.origin = mRec.p;
				delta = false;
				medium = true;
			}
			else if (!r2.hasHit())
				break;
			else
			{
				if (medium)
					throughput *= mRec.transmittance / mRec.pdfFailure;
				Vec3f wo = bssrdf ? r.direction : -r.direction;
				r2.getBsdfSample(-wo, r(r2.m_fDist), bRec, ETransportMode::EImportance, &rng);
				if ((DIRECT && depth > 0) || !DIRECT)
					if (r2.getMat().bsdf.hasComponent(ESmooth) && dot(bRec.dg.sys.n, wo) > 0.0f)
						wasStored |= storePhoton(dg.P, throughput * Le, wo, bRec.dg.sys.n, delta ? PhotonType::pt_Caustic : PhotonType::pt_Diffuse, g_Map);
				Spectrum f = r2.getMat().bsdf.sample(bRec, rng.randomFloat2());
				delta = bRec.sampledType & ETypeCombinations::EDelta;
				if (!bssrdf && r2.getMat().GetBSSRDF(bRec.dg, &bssrdf))
					bRec.wo.z *= -1.0f;
				else
				{
					if (!bssrdf)
						throughput *= f;
					bssrdf = 0;
					medium = false;
				}

				r = Ray(bRec.dg.P, bRec.getOutgoing());
			}
		}
		if (wasStored)
			atomicInc(&g_Map.m_uPhotonNumEmitted, 0xffffffff);
	}

	g_RNGData(rng);
}

__global__ void buildHashGrid()
{
	unsigned int idx = threadIdx.y * blockDim.x + threadIdx.x + blockDim.x * blockDim.y * blockIdx.x;
	if (idx < g_Map.m_uPhotonBufferLength)
	{
		k_pPpmPhoton& e = g_Map.m_pPhotons[idx];
		Vec3f pos = g_Map.m_pPhotonPositions[idx];
		const k_PhotonMap<k_HashGrid_Reg>& map = (&g_Map.m_sSurfaceMap)[e.getType()];
		e.setPos(map.m_sHash, map.m_sHash.Transform(pos), pos);
		unsigned int i = map.m_sHash.Hash(pos);
		unsigned int k = atomicExch(map.m_pDeviceHashGrid + i, idx);
		e.setNext(k);
	}
}

/*CUDA_DEVICE unsigned int g_NextPhotonIdx;
__global__ void reorderPhotonBuffer()
{
	unsigned int idx = threadIdx.y * blockDim.x + threadIdx.x + blockDim.x * blockDim.y * blockIdx.x;
	if (idx < g_Map.m_sSurfaceMap.m_uGridLength)
	{
		unsigned int i = g_Map.m_sSurfaceMap.m_pDeviceHashGrid[idx], N = 0;
		while (i != 0xffffffff && i != 0xffffff && N < 30)
		{
			k_pPpmPhoton e = g_Map.m_pPhotons[i];
			N++;
			i = e.getNext();
		}
		if (N)
		{
			unsigned int start = atomicAdd(&g_NextPhotonIdx, N);
			i = g_Map.m_sSurfaceMap.m_pDeviceHashGrid[idx];
			g_Map.m_sSurfaceMap.m_pDeviceHashGrid[idx] = start;
			for (unsigned int j = 0; j < N; j++)
			{
				k_pPpmPhoton e = g_Map.m_pPhotons[i];
				g_Map.m_pPhotons2[start + j] = e;
				i = e.getNext();
			}
		}
	}
}*/

/*__global__ void buildHashGridLinkedList(float a_Radius)
{
	const float r2 = a_Radius * a_Radius;
	unsigned int idx = threadId;
	if (idx < g_Map.m_uPhotonBufferLength)
	{
		k_pPpmPhoton& e = g_Map.m_pPhotons[idx];
		k_PhotonMap<k_HashGrid_Reg>& map = (&g_Map.m_sSurfaceMap)[e.getType()];
		if (e.getType() == PhotonType::pt_Caustic || e.getType() == PhotonType::pt_Diffuse)
		{
			Frame f = Frame(e.getNormal());
			f.t *= a_Radius;
			f.s *= a_Radius;
			f.n *= a_Radius;
			float3 a = -1.0f * f.t - f.s, b = f.t - f.s, c = -1.0f * f.t + f.s, d = f.t + f.s;
			float3 low = min(min(a, b), min(c, d)) + e.getPos(), high = max(max(a, b), max(c, d)) + e.getPos();
			uint3 lo = map.m_sHash.Transform(low), hi = map.m_sHash.Transform(high);
			for (unsigned int a = lo.x; a <= hi.x; a++)
			for (unsigned int b = lo.y; b <= hi.y; b++)
			for (unsigned int c = lo.z; c <= hi.z; c++)
			{
				unsigned int hash_idx = map.m_sHash.Hash(make_uint3(a, b, c));
				unsigned int list_idx = atomicInc(&map.m_uLinkedListUsed, 0xffffffff);
				if (list_idx < map.m_uLinkedListLength)
				{
					unsigned int prev_list_idx = atomicExch(map.m_pDeviceHashGrid + hash_idx, list_idx);
					map.m_pDeviceLinkedList[list_idx] = make_uint2(idx, prev_list_idx);
				}
				else printf("list_idx = %d, length = %d", list_idx, map.m_uLinkedListLength);
			}
		}
	}
}*/

void k_sPpmTracer::doPhotonPass()
{
	cudaMemcpyToSymbol(g_Map, &m_sMaps, sizeof(m_sMaps));
	while (!m_sMaps.PassFinished())
	{
		if (m_bDirect)
			k_PhotonPass<true> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >();
		else k_PhotonPass<false> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >();
		cudaMemcpyFromSymbol(&m_sMaps, g_Map, sizeof(m_sMaps));
	}
	buildHashGrid<< <m_sMaps.m_uPhotonBufferLength / (32 * 6) + 1, dim3(32, 6, 1) >> >();
	//ZeroSymbol(g_NextPhotonIdx);
	//reorderPhotonBuffer << < m_sMaps.m_sSurfaceMap.m_uGridLength / (32 * 6) + 1, dim3(32, 6, 1) >> >();
	cudaMemcpyFromSymbol(&m_sMaps, g_Map, sizeof(m_sMaps));
	//swapk(&m_sMaps.m_pPhotons, &m_sMaps.m_pPhotons2);
}

CUDA_GLOBAL void estimateRadius(unsigned int w, unsigned int h, k_AdaptiveEntry* E, k_PhotonMapCollection<true, k_pPpmPhoton> photonMap, float maxR, float targetNumPhotons)
{
	k_PhotonMap<k_HashGrid_Reg>& map = photonMap.m_sSurfaceMap;
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if (x < w && y < h)
	{
		Ray r = g_SceneData.GenerateSensorRay(x, y);
		TraceResult r2 = k_TraceRay(r);
		int N = 0, d = 0;
		while (r2.hasHit() && d++ < 10)
		{
			DifferentialGeometry dg;
			BSDFSamplingRecord bRec(dg);
			r2.getBsdfSample(r, bRec, ERadiance, 0);
			if (r2.getMat().bsdf.hasComponent(EDelta))
			{
				r2.getMat().bsdf.sample(bRec, Vec2f(0));
				r = Ray(dg.P, bRec.getOutgoing());
				r2 = k_TraceRay(r);
			}
			else
			{
				Frame sys = Frame(bRec.dg.n);
				sys.t *= maxR;
				sys.s *= maxR;
				Vec3f a = -1.0f * sys.t - sys.s, b = sys.t - sys.s, c = -1.0f * sys.t + sys.s, d = sys.t + sys.s;
				Vec3f low = min(min(a, b), min(c, d)) + bRec.dg.P, high = max(max(a, b), max(c, d)) + bRec.dg.P;
				Vec3u lo = map.m_sHash.Transform(low), hi = map.m_sHash.Transform(high);
				for (unsigned int a = lo.x; a <= hi.x; a++)
					for (unsigned int b = lo.y; b <= hi.y; b++)
						for (unsigned int c = lo.z; c <= hi.z; c++)
						{
							unsigned int i0 = map.m_sHash.Hash(make_uint3(a, b, c)), i = map.m_pDeviceHashGrid[i0];
							while (i != 0xffffffff && i != 0xffffff)
							{
								k_pPpmPhoton e = photonMap.m_pPhotons[i];
								if (distanceSquared(e.getPos(map.m_sHash, Vec3u(a,b,c)), bRec.dg.P) < maxR * maxR)//&& dot(n, bRec.dg.sys.n) > 0.8f
								{
									N++;
								}
								i = e.getNext();
							}
						}
				break;
			}
		}
		k_AdaptiveEntry& e = E[y * w + x];
		if (N == 0)
			e.r = e.rd = maxR;
		else
		{
			//A_max = PI * maxR^2, density = N / A_max
			//target = density * A_correct = density * PI * r * r
			//r = sqrt(target / (density * PI))
			float d = float(N) / (PI * maxR * maxR);
			e.r = e.rd = math::sqrt(targetNumPhotons / (PI * d));
		}
	}
}

void k_sPpmTracer::estimatePerPixelRadius()
{
	int p0 = 16;
	estimateRadius << <dim3(w / p0 + 1, h / p0 + 1), dim3(p0, p0) >> >(w, h, m_pEntries, m_sMaps, 5 * m_fInitialRadius, 20);
}

CUDA_DEVICE unsigned int g_uMaxGridCounter;

CUDA_GLOBAL void visGrid(unsigned int w, unsigned int h, e_Image I, k_PhotonMapCollection<true, k_pPpmPhoton> photonMap, float scale)
{
	k_PhotonMap<k_HashGrid_Reg>& map = photonMap.m_sSurfaceMap;
	unsigned int x = threadIdx.x + blockDim.x * blockIdx.x, y = threadIdx.y + blockDim.y * blockIdx.y;
	if (x < w && y < h)
	{
		Ray r = g_SceneData.GenerateSensorRay(x, y);
		TraceResult r2 = k_TraceRay(r);
		unsigned int N = 0, d = 0;
		while (r2.hasHit() && d++ < 10)
		{
			DifferentialGeometry dg;
			BSDFSamplingRecord bRec(dg);
			r2.getBsdfSample(r, bRec, ERadiance, 0);
			if (r2.getMat().bsdf.hasComponent(EDelta))
			{
				r2.getMat().bsdf.sample(bRec, Vec2f(0));
				r = Ray(dg.P, bRec.getOutgoing());
				r2 = k_TraceRay(r);
			}
			else
			{
				Vec3u idx = map.m_sHash.Transform(dg.P);
				unsigned int i0 = map.m_sHash.Hash(idx), i = map.m_pDeviceHashGrid[i0];
				while (i != 0xffffffff && i != 0xffffff)
				{
					k_pPpmPhoton e = photonMap.m_pPhotons[i];
					N++;
					i = e.getNext();
				}
				break;
			}
		}
		atomicMax(&g_uMaxGridCounter, N);
		I.AddSample(x, y, Spectrum(0, 0, N > scale / 2 ? 1 : 0));//N / scale
	}
}

void k_sPpmTracer::visualizeGrid(e_Image* I)
{
	I->Clear();
	ZeroSymbol(g_uMaxGridCounter);
	int p0 = 16;
	visGrid << <dim3(w / p0 + 1, h / p0 + 1), dim3(p0, p0) >> >(w, h, *I, m_sMaps, m_uVisLastMax);
	cudaMemcpyFromSymbol(&m_uVisLastMax, g_uMaxGridCounter, sizeof(unsigned int));
}