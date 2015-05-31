#pragma once

#include <MathTypes.h>
#include "e_SceneBVH_device.h"

class e_Node;
class e_Mesh;
struct e_KernelMesh;
template<typename T> class e_Stream;
template<typename H, typename D> class e_BufferReference;

class e_SceneBVH
{
public:
	struct BVHIndex;
private:
	int m_sBvhNodeCount;
	e_Stream<e_BVHNodeData>* m_pNodes;
	e_Stream<float4x4>* m_pTransforms;
	e_Stream<float4x4>* m_pInvTransforms;
	int startNode;

	struct BVHNodeInfo;
	class BuilderCLB;
	struct SceneInfo;

	std::vector<BVHNodeInfo> bvhNodeData;
	std::vector<BVHIndex> nodeToBVHNode;

	std::vector<e_BufferReference<e_Node, e_Node>> nodesToRecompute;
	std::vector<e_BufferReference<e_Node, e_Node>> nodesToInsert;
	std::vector<e_BufferReference<e_Node, e_Node>> nodesToRemove;

	SceneInfo* info;
public:
	AABB m_sBox;
	e_SceneBVH(unsigned int a_NodeCount);
	~e_SceneBVH();
	bool Build(e_BufferReference<e_Node, e_Node>, e_BufferReference<e_Mesh, e_KernelMesh> a_Meshes);
	e_KernelSceneBVH getData(bool devicePointer = true);
	unsigned int getSizeInBytes();
	void setTransform(e_BufferReference<e_Node, e_Node> n, const float4x4& mat);
	void invalidateNode(e_BufferReference<e_Node, e_Node> n);
	void addNode(e_BufferReference<e_Node, e_Node> n);
	void removeNode(e_BufferReference<e_Node, e_Node> n);
	const float4x4& getNodeTransform(e_BufferReference<e_Node, e_Node> n);
	e_BVHNodeData* getBVHNode(unsigned int i);
	bool needsBuild();
	void printGraph(const std::string& path, e_BufferReference<e_Node, e_Node> a_Nodes);
private:
	void removeNodeAndCollapse(BVHIndex nodeIdx, BVHIndex childIdx);
	void insertNode(BVHIndex bvhNodeIdx, unsigned int nodeIdx, const AABB& nodeWorldBox);
	int getChildIdxInLocal(BVHIndex nodeIdx, BVHIndex childIdx);
	void setChild(BVHIndex nodeIdx, BVHIndex childIdx, int localIdxToSetTo);
	AABB getWorldNodeBox(e_BufferReference<e_Node, e_Node> ref);
	void sahModified(BVHIndex nodeIdx, const AABB& box, float& leftSAH, float& rightSAH);
	int validateTree(BVHIndex idx, BVHIndex parent);
	void propagateBBChange(BVHIndex idx, const AABB& box, int localChildIdx);
	AABB getBox(BVHIndex idx);
};
