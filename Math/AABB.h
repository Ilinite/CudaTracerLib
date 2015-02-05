#pragma once
#include "Vector.h"
#include "float4x4.h"
#include "Ray.h"

struct AABB
{
	Vec3f minV;
	Vec3f maxV;
	CUDA_FUNC_IN AABB()
	{
	}
	CUDA_FUNC_IN AABB(const Vec3f& vMin, const Vec3f& vMax)
	{
		minV = min(vMin, vMax);
		maxV = max(vMin, vMax);
	}
	CUDA_FUNC_IN void Enlarge(const AABB& a)
	{
		minV = min(minV, a.minV);
		maxV = max(maxV, a.maxV);
	}
	CUDA_FUNC_IN void Enlarge(const Vec3f& v)
	{
		minV = min(minV, v);
		maxV = max(maxV, v);
	}
	CUDA_FUNC_IN void intersect(const AABB& box)
	{
		minV = max(box.minV, minV);
		maxV = min(box.maxV, maxV);
	}
	CUDA_FUNC_IN float Area() const
	{
		Vec3f a = (maxV - minV);
		return 2.0f * (a.x * a.y + a.x * a.z + a.y * a.z);
	}
	CUDA_FUNC_IN float volume() const
	{
		Vec3f a = (maxV - minV);
		return a.x * a.y * a.z;
	}
	CUDA_FUNC_IN float w() const { return maxV[0]-minV[0]; }
	CUDA_FUNC_IN float h() const { return maxV[1]-minV[1]; }
	CUDA_FUNC_IN float d() const { return maxV[2]-minV[2]; }
	CUDA_FUNC_IN AABB Transform(const float4x4& mat) const
	{
		Vec3f d = maxV - minV;
#define A(x,y,z) Vec3f(x,y,z) * d + minV
		Vec3f v[8] = { A(0, 0, 0), A(1, 0, 0), A(1, 0, 1), A(0, 0, 1),
					   A(0,1,0), A(1,1,0), A(1,1,1), A(0,1,1)};
		Vec3f mi = Vec3f(FLT_MAX), ma = Vec3f(-FLT_MAX);
		for(int i = 0; i < 8; i++)
		{
			Vec3f q = mat.TransformPoint(v[i]);
			mi = min(q, mi);
			ma = max(q, ma);
		}
		return AABB(mi, ma);
#undef A
	}
	//Ensures that every dim != zero
	CUDA_FUNC_IN AABB Inflate() const
	{
		AABB b;
		b.minV = minV;
		b.maxV = maxV;
		for(int i = 0; i < 3; i++)
			if (abs(b.maxV[i] - b.minV[i]) < EPSILON)
			{
				b.maxV[i] += (float)EPSILON;
				b.minV[i] -= (float)EPSILON;
			}
		return b;
	}
	//Enlarges the box by the factor
	CUDA_FUNC_IN AABB Enlarge(float f = 0.015f) const
	{
		Vec3f q = (maxV - minV) / 2.0f, m = (maxV + minV) / 2.0f;
		float e2 = 1.0f + f;
		AABB box;
		box.maxV = m + q * e2;
		box.minV = m - q * e2;
		return box;
	}
	CUDA_FUNC_IN bool Contains(const Vec3f& p) const
	{
		return minV.x <= p.x && p.x <= maxV.x && minV.y <= p.y && p.y <= maxV.y && minV.z <= p.z && p.z <= maxV.z;
	}
	CUDA_FUNC_IN Vec3f Size() const
	{
		return maxV - minV;
	}
	CUDA_FUNC_IN Vec3f Center() const
	{
		return (maxV + minV) / 2.0f;
	}
	static CUDA_FUNC_IN AABB Identity()
	{
		AABB b;
		b.minV = Vec3f(FLT_MAX);
		b.maxV = Vec3f(-FLT_MAX);
		return b;
	}

	CUDA_FUNC_IN bool Intersect_FMA(const Vec3f& I, const Vec3f& OI, float* min = 0, float* max = 0) const
	{
		float tx1 = minV.x * I.x - OI.x;
		float tx2 = maxV.x * I.x - OI.x;
		float ty1 = minV.y * I.y - OI.y;
		float ty2 = maxV.y * I.y - OI.y;
		float tz1 = minV.z * I.z - OI.z;
		float tz2 = maxV.z * I.z - OI.z;
		float mi = math::spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, 0);
		float ma = math::spanEndKepler(tx1, tx2, ty1, ty2, tz1, tz2, FLT_MAX);
		bool b = ma > mi && ma > 0;
		if(min && b)
			*min = mi;
		if(max && b)
			*max = ma;
		return b;
	}

	CUDA_FUNC_IN bool Intersect(const Vec3f& m_Dir, const Vec3f& m_Ori, float* min = 0, float* max = 0) const
	{
		float tx1 = (minV.x - m_Ori.x) / m_Dir.x;
		float tx2 = (maxV.x - m_Ori.x) / m_Dir.x;
		float ty1 = (minV.y - m_Ori.y) / m_Dir.y;
		float ty2 = (maxV.y - m_Ori.y) / m_Dir.y;
		float tz1 = (minV.z - m_Ori.z) / m_Dir.z;
		float tz2 = (maxV.z - m_Ori.z) / m_Dir.z;
		float mi = math::spanBeginKepler(tx1, tx2, ty1, ty2, tz1, tz2, 0);
		float ma = math::spanEndKepler(tx1, tx2, ty1, ty2, tz1, tz2, FLT_MAX);
		bool b = ma > mi && ma > 0;
		if(min && b)
			*min = mi;
		if(max && b)
			*max = ma;
		return b;
	}

	CUDA_FUNC_IN bool Intersect(const Ray& r, float* min = 0, float* max = 0) const
	{
		return Intersect(r.direction, r.origin, min, max);
	}
};