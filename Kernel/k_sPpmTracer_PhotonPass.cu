#include "k_sPpmTracer.h"
#include "k_TraceHelper.h"

CUDA_DEVICE k_PhotonMapCollection g_Map;

CUDA_FUNC_IN float3 smapleHG(float g, CudaRNG& rng, float3& wi)
{
	float sqrTerm = (1 - g * g) / (1 - g + 2 * g * rng.randomFloat());
	float cosTheta = g < EPSILON ? 1.0f - 2.0f * rng.randomFloat() : (1 + g * g - sqrTerm * sqrTerm) / (2 * g);
	float sinTheta = sqrtf(1.0f-cosTheta*cosTheta);
	float r = rng.randomFloat();
	float sinPhi = sinf(2*PI*r), cosPhi = cosf(2*PI*r);
	float3 r2 = make_float3(sinTheta * cosPhi, sinTheta * sinPhi, cosTheta);
	return Onb(-1.0f * wi).localToworld(r2);
}

CUDA_ONLY_FUNC bool TracePhoton(Ray& r, float3 Le, CudaRNG& rng)
{
	e_KernelAggregateVolume& V = g_SceneData.m_sVolume;
	TraceResult r2;
	r2.Init();
	int depth = -1;
	while(++depth < 12 && k_TraceRay<true>(r.direction, r.origin, &r2))
	{
		if(V.HasVolumes())
		{
			float minT, maxT;
			while(V.IntersectP(r, 0, r2.m_fDist, &minT, &maxT))
			{
				if(minT != 0)
				{
					maxT -= minT;
					r2.m_fDist -= minT;
					r.origin += r.direction * minT;
					minT = 0;
				}
				float3 x = r(minT), w = -r.direction;
				float3 sigma_s = V.sigma_s(x, w), sigma_t = V.sigma_t(x, w);
				float d = 1.0f / (fsumf(sigma_t) / 3.0f);//-logf(rng.randomFloat())
				bool cancel = d >= (maxT - minT) || d >= r2.m_fDist;
				d = clamp(d, 0.0f, maxT - minT);
				float3 transmittance = exp(-V.tau(r, 0, d));
				Le = Le * transmittance;
				if(!g_Map.StorePhoton<false>(r(minT + d * 0.5f), Le, w, make_float3(0,0,0)))
					return false;
				if(cancel)
					break;
				float A = fsumf(sigma_s / sigma_t) / 3.0f;
				if(rng.randomFloat() <= A)
				{
					Le /= A;
					//float3 wo = r.direction;
					float3 wo = smapleHG(((e_HomogeneousVolumeDensity*)V.m_pVolumes)->g, rng, w);
					Le *= V.p(x, w, wo);
					r.origin = r(d);
					r.direction = wo;
					r2.Init();
					if(!k_TraceRay<true>(r.direction, r.origin, &r2))
						return true;
				}
				else break;//Absorption
			}
		}
		float3 x = r(r2.m_fDist);
		e_KernelBSDF bsdf = r2.m_pTri->GetBSDF(r2.m_fUV, r2.m_pNode->getWorldMatrix(), g_SceneData.m_sMatData.Data, r2.m_pNode->m_uMaterialOffset);
		float3 wo = -r.direction, wi;
		if(bsdf.NumComponents(BxDFType(BSDF_REFLECTION | BSDF_TRANSMISSION | BSDF_DIFFUSE )))
			if(!g_Map.StorePhoton<true>(x, Le, wo, bsdf.ng))
				return false;
		float pdf;
		BxDFType sampledType;
		float3 f = bsdf.Sample_f(wo, &wi, BSDFSample(rng), &pdf, BSDF_ALL, &sampledType);
		if(pdf == 0 || fsumf(f) == 0)
			break;
		float3 ac = Le * f * AbsDot(wi, bsdf.sys.m_normal) / pdf;
		float prob = MIN(1.0f, fmaxf(ac) / fmaxf(Le));
		if(rng.randomFloat() > prob)
			break;
		Le = ac / prob;
		r = Ray(r(r2.m_fDist), wi);
		r2.Init();
	}
	return true;
}

__global__ void k_PhotonPass(unsigned int spp, float angle, float angle2)
{ 
	const unsigned int a_MaxDepth = 10;
	CudaRNG rng = g_RNGData();
	for(int _photonNum = 0; _photonNum < spp; _photonNum++)
	{
		int li = (int)((float)g_SceneData.m_sLightData.UsedCount * rng.randomFloat());
		float lightPdf = 1.0f / (float)g_SceneData.m_sLightData.UsedCount;
	label001:
		Ray photonRay;
		float3 Nl;
		float pdf;
		float3 Le = g_SceneData.m_sLightData[li].Sample_L(rng, &photonRay, &Nl, &pdf);
		/*photonRay.origin = g_SceneData.m_sLightData[li].box.Center();// + make_float3(0,-35,0)
		photonRay.direction = normalize(make_float3(rng.randomFloat() * 2.0f - 1.0f, -rng.randomFloat(), rng.randomFloat() * 2.0f - 1.0f));
		float a = acos(-photonRay.direction.y);
		if((a < Radians(angle) || a > Radians(angle + angle2)) && rng.randomFloat() < 0.75f)
			goto label001;*/
		if(pdf == 0 || ISBLACK(Le))
			continue;
		float3 alpha = (AbsDot(Nl, photonRay.direction) * Le) / (pdf * lightPdf);
		if(TracePhoton(photonRay, alpha, rng))
			atomicInc(&g_Map.m_uPhotonNumEmitted, -1);
		else break;
	}
	g_RNGData(rng);
}

void k_sPpmTracer::doPhotonPass()
{
	cudaMemcpyToSymbol(g_Map, &m_sMaps, sizeof(k_PhotonMapCollection));
	k_INITIALIZE(m_pScene->getKernelSceneData());
	k_STARTPASS(m_pScene, m_pCamera, m_sRngs);
	const unsigned long long p0 = 6 * 32, spp = 3, n = 180, PhotonsPerPass = p0 * n * spp;
	k_PhotonPass<<< n, p0 >>>(spp,20,5);
	cudaThreadSynchronize();
	cudaMemcpyFromSymbol(&m_sMaps, g_Map, sizeof(k_PhotonMapCollection));
}