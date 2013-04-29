#pragma once

#include "..\Math\vector.h"
#include "e_DataStream.h"
#include "e_TriangleData.h"
#include "e_HostDeviceBuffer.h"
#include "e_KernelMaterial.h"

struct e_KernelMesh
{
	unsigned int m_uTriangleOffset;
	unsigned int m_uBVHNodeOffset;
	unsigned int m_uBVHTriangleOffset;
	unsigned int m_uBVHIndicesOffset;
	unsigned int m_uStdMaterialOffset;
	unsigned int OFF[3];
};

struct e_TriIntersectorData
{
//      triWoop[triOfs*16 + 0 ] = Vec4f(woopZ)
//      triWoop[triOfs*16 + 16] = Vec4f(woopU)
//      triWoop[triOfs*16 + 32] = Vec4f(woopV)
	float4 a,b,c,d;
	CUDA_FUNC_IN void setData(float3& v0, float3& v1, float3& v2)
	{
		float3 p = v0 - v2;
		float3 q = v1 - v2;
		float3 d = -cross(p, q);
		float3 c = v2;
		float4x4 m( p.x, q.x, d.x, c.x,
					p.y, q.y, d.y, c.y,
					p.z, q.z, d.z, c.z,
					  0,   0,   0,   1  );
		m = m.Inverse();
		this->a = make_float4(m[2].x, m[2].y, m[2].z, -m[2].w);
		this->b = make_float4(m[0].x, m[0].y, m[0].z, m[0].w);
		this->c = make_float4(m[1].x, m[1].y, m[1].z, m[1].w);
	}

	CUDA_FUNC_IN void getData(float3& v0, float3& v1, float3& v2)
	{
		float4x4 m(b.x, b.y, b.z, b.w, c.x, c.y, c.z, c.w, a.x, a.y, a.z, -a.w, 0, 0, 0, 1);
		m = m.Inverse();
		float3 e02 = make_float3(m.X.x, m.Y.x, m.Z.x), e12 = make_float3(m.X.y, m.Y.y, m.Z.y);
		v2 = make_float3(m.X.w, m.Y.w, m.Z.w);
		v0 = v2 + e02;
		v1 = v2 + e12;
	}
};

struct e_BVHNodeData
{
//      nodes[innerOfs + 0 ] = Vec4f(c0.lo.x, c0.hi.x, c0.lo.y, c0.hi.y)
//      nodes[innerOfs + 16] = Vec4f(c1.lo.x, c1.hi.x, c1.lo.y, c1.hi.y)
//      nodes[innerOfs + 32] = Vec4f(c0.lo.z, c0.hi.z, c1.lo.z, c1.hi.z)
	float4 a,b,c,d;
	int2 getChildren()
	{
		return *(int2*)&d;
	}
	CUDA_FUNC_IN void getBox(AABB& left, AABB& right)
	{
		left.minV = make_float3(a.x, a.z, c.x);
		left.maxV = make_float3(a.y, a.w, c.y);
		right.minV = make_float3(b.x, b.z, c.z);
		right.maxV = make_float3(b.y, b.w, c.w);
	}
	CUDA_FUNC_IN AABB getLeft()
	{
		return AABB(make_float3(a.x, a.z, c.x), make_float3(a.y, a.w, c.y));
	}
	CUDA_FUNC_IN AABB getRight()
	{
		return AABB(make_float3(b.x, b.z, c.z), make_float3(b.y, b.w, c.w));
	}
	CUDA_FUNC_IN void setBox(AABB& c0, AABB& c1)
	{
		a = make_float4(c0.minV.x, c0.maxV.x, c0.minV.y, c0.maxV.y);
		b = make_float4(c1.minV.x, c1.maxV.x, c1.minV.y, c1.maxV.y);
		c = make_float4(c0.minV.z, c0.maxV.z, c1.minV.z, c1.maxV.z);
	}
	CUDA_FUNC_IN void setLeft(AABB& c0)
	{
		a = make_float4(c0.minV.x, c0.maxV.x, c0.minV.y, c0.maxV.y);
		c.x = c0.minV.z;
		c.y = c0.maxV.z;
	}
	CUDA_FUNC_IN void setRight(AABB& c1)
	{
		b = make_float4(c1.minV.x, c1.maxV.x, c1.minV.y, c1.maxV.y);
		c.z = c1.minV.z;
		c.w = c1.maxV.z;
	}
	CUDA_FUNC_IN void setChildren(int2 c)
	{
		*(int2*)&d = c;
	}
	void setDummy()
	{
		AABB std(make_float3(0), make_float3(0));
		setLeft(std);
		setRight(std);
		setChildren(make_int2(0,0));
	}
};



#include "cuda_runtime.h"
#include "..\Base\FileStream.h"
#include "e_SceneInitData.h"

class e_Mesh
{
public:
	AABB m_sLocalBox;
public:
	e_DataStreamReference<e_TriangleData> m_sTriInfo;
	e_DataStreamReference<e_KernelMaterial> m_sMatInfo;
	e_DataStreamReference<e_BVHNodeData> m_sNodeInfo;
	e_DataStreamReference<e_TriIntersectorData> m_sIntInfo;
	e_DataStreamReference<int> m_sIndicesInfo;
	e_KernelMesh m_sData;
public:
	e_Mesh() {}
	e_Mesh(InputStream& a_In, e_DataStream<e_TriIntersectorData>* a_Stream0, e_DataStream<e_TriangleData>* a_Stream1, e_DataStream<e_BVHNodeData>* a_Stream2, e_DataStream<int>* a_Stream3, e_DataStream<e_KernelMaterial>* a_Stream4);
	void Free(e_DataStream<e_TriIntersectorData>& a_Stream0, e_DataStream<e_TriangleData>& a_Stream1, e_DataStream<e_BVHNodeData>& a_Stream2, e_DataStream<int>& a_Stream3, e_DataStream<e_KernelMaterial>& a_Stream4);
	static void CompileObjToBinary(const char* a_InputFile, OutputStream& a_Out);
	static void CompileNifToBinary(const char* a_InputFile, OutputStream& a_Out);
	static e_SceneInitData ParseBinary(const char* a_InputFile);
	e_KernelMesh getKernelData()
	{
		return m_sData;
	}
	e_DataStreamReference<e_KernelMaterial> getMaterialInfo()
	{
		return m_sMatInfo;
	}
	e_KernelMesh createKernelData()
	{
		m_sData.m_uBVHIndicesOffset = m_sIndicesInfo.getIndex();
		m_sData.m_uBVHNodeOffset = m_sNodeInfo.getIndex() * sizeof(e_BVHNodeData) / sizeof(float4);
		m_sData.m_uBVHTriangleOffset = m_sIntInfo.getIndex() * sizeof(e_TriIntersectorData) / sizeof(float4);
		m_sData.m_uTriangleOffset = m_sTriInfo.getIndex();
		m_sData.m_uStdMaterialOffset = m_sMatInfo.getIndex();
		return m_sData;
	}
	unsigned int getTriangleCount()
	{
		return m_sTriInfo.getLength();
	}
};