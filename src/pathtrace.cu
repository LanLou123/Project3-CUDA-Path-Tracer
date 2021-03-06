#include <cstdio>
#include <cuda.h>
#include <cmath>
#include <thrust/execution_policy.h>
#include <thrust/random.h>
#include <thrust/remove.h>
#include <thrust/device_vector.h>
#include <thrust/partition.h>
#include <thrust/device_vector.h>

#include "sceneStructs.h"
#include "scene.h"
#include "glm/glm.hpp"
#include "glm/gtx/norm.hpp"
#include "utilities.h"
#include "pathtrace.h"
#include "intersections.h"
#include "interactions.h"


#define ERRORCHECK 1

#define COMPACTION 1
#define SORTBYMATERIAL 0
#define CACHE 0
#define ANTIALIASING 0
//#define TOGGLEKD
#define DOFTOGGLE 0
#define FULLLIGHT 1

#define FILENAME (strrchr(__FILE__, '/') ? strrchr(__FILE__, '/') + 1 : __FILE__)
#define checkCUDAError(msg) checkCUDAErrorFn(msg, FILENAME, __LINE__)
void checkCUDAErrorFn(const char *msg, const char *file, int line) {
#if ERRORCHECK
    cudaDeviceSynchronize();
    cudaError_t err = cudaGetLastError();
    if (cudaSuccess == err) {
        return;
    }

    fprintf(stderr, "CUDA error");
    if (file) {
        fprintf(stderr, " (%s:%d)", file, line);
    }
    fprintf(stderr, ": %s: %s\n", msg, cudaGetErrorString(err));
#  ifdef _WIN32
    getchar();
#  endif
    exit(EXIT_FAILURE);
#endif
}


struct _test_bounce_ {
	__host__ __device__ bool operator()(const PathSegment tmp)
	{
		bool have_bounce = false;
		if (tmp.remainingBounces > 0) have_bounce = true;
		return (have_bounce);
	}
};

struct _test_material_
{
	__host__ __device__ bool operator()(const ShadeableIntersection _first, const ShadeableIntersection _second)
	{
		bool returnval = _first.materialId > _second.materialId ? false : true;
		return returnval;
	}
};

__host__ __device__
thrust::default_random_engine makeSeededRandomEngine(int iter, int index, int depth) {
    int h = utilhash((1 << 31) | (depth << 22) | iter) ^ utilhash(index);
    return thrust::default_random_engine(h);
}

//Kernel that writes the image to the OpenGL PBO directly.
__global__ void sendImageToPBO(uchar4* pbo, glm::ivec2 resolution,
        int iter, glm::vec3* image) {
    int x = (blockIdx.x * blockDim.x) + threadIdx.x;
    int y = (blockIdx.y * blockDim.y) + threadIdx.y;

    if (x < resolution.x && y < resolution.y) {
        int index = x + (y * resolution.x);
        glm::vec3 pix = image[index];

        glm::ivec3 color;
        color.x = glm::clamp((int) (pix.x / iter * 255.0), 0, 255);
        color.y = glm::clamp((int) (pix.y / iter * 255.0), 0, 255);
        color.z = glm::clamp((int) (pix.z / iter * 255.0), 0, 255);

        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = 0;
        pbo[index].x = color.x;
        pbo[index].y = color.y;
        pbo[index].z = color.z;
    }
}

static Scene * hst_scene = NULL;
static glm::vec3 * dev_image = NULL;
static Geom * dev_geoms = NULL;
static Material * dev_materials = NULL;
static PathSegment * dev_paths = NULL;
static mesh * dev_meshs = NULL;
static Triangle * dev_triangles = NULL;
static ShadeableIntersection * dev_intersections = NULL;
static ShadeableIntersection * dev_intersections_cache = NULL;
static GPUKDtreeNode *dev_KDtreenode = NULL;
static int *dev_gputriidxlst;
static int *dev_idxchecker;
static const int MAX_NODE_SIZE = 70000;

//for dispersion wavelength
static float *dev_wavelen;
// TODO: static variables for device memory, any extra info you need, etc
// ...

void pathtraceInit(Scene *scene) {
    hst_scene = scene;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

    cudaMalloc(&dev_image, pixelcount * sizeof(glm::vec3));
    cudaMemset(dev_image, 0, pixelcount * sizeof(glm::vec3));

  	cudaMalloc(&dev_paths, pixelcount * sizeof(PathSegment));

  	cudaMalloc(&dev_geoms, scene->geoms.size() * sizeof(Geom));
  	cudaMemcpy(dev_geoms, scene->geoms.data(), scene->geoms.size() * sizeof(Geom), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_meshs, scene->meshs.size() * sizeof(mesh));
	cudaMemcpy(dev_meshs, scene->meshs.data(), scene->meshs.size() * sizeof(mesh), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_triangles, scene->triangles.size() * sizeof(Triangle));
	cudaMemcpy(dev_triangles, scene->triangles.data(), scene->triangles.size() * sizeof(Triangle), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_materials, scene->materials.size() * sizeof(Material));
  	cudaMemcpy(dev_materials, scene->materials.data(), scene->materials.size() * sizeof(Material), cudaMemcpyHostToDevice);

  	cudaMalloc(&dev_intersections, pixelcount * sizeof(ShadeableIntersection));
  	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection));
	cudaMemset(dev_intersections_cache, 0, pixelcount * sizeof(ShadeableIntersection));

	cudaMalloc(&dev_idxchecker, scene->KDtreeforGPU.size() * sizeof(int));

	cudaMalloc(&dev_wavelen, pixelcount * sizeof(float));
	cudaMemcpy(dev_wavelen, scene->wavelen.data(), scene->wavelen.size() * sizeof(float), cudaMemcpyHostToDevice);
#ifdef TOGGLEKD



	cudaMalloc(&dev_KDtreenode, scene->KDtreeforGPU.size() * sizeof(GPUKDtreeNode));
	cudaMemcpy(dev_KDtreenode, scene->KDtreeforGPU.data(), scene->KDtreeforGPU.size() * sizeof(GPUKDtreeNode), cudaMemcpyHostToDevice);

	cudaMalloc(&dev_gputriidxlst, scene->triangleidxforGPU.size() * sizeof(int));
	cudaMemcpy(dev_gputriidxlst, scene->triangleidxforGPU.data(), scene->triangleidxforGPU.size() * sizeof(int), cudaMemcpyHostToDevice);

	
#endif // TOGGLEKD
    // TODO: initialize any extra device memeory you need

    checkCUDAError("pathtraceInit");
}

void pathtraceFree() {
    cudaFree(dev_image);  // no-op if dev_image is null
  	cudaFree(dev_paths);
  	cudaFree(dev_geoms);
	cudaFree(dev_meshs);
	cudaFree(dev_triangles);
  	cudaFree(dev_materials);
  	cudaFree(dev_intersections);
	cudaFree(dev_wavelen);
#ifdef TOGGLEKD
	cudaFree(dev_KDtreenode);
	cudaFree(dev_gputriidxlst);

#endif
	cudaFree(dev_idxchecker);
    // TODO: clean up any extra device memory you created

    checkCUDAError("pathtraceFree");
}
//disksample code from https://pub.dartlang.org/documentation/dartray/0.0.1/core/ConcentricSampleDisk.html
__device__ __host__ glm::vec2 ConcentricSampleDisk(float rand_x, float rand_y)
{
	float r, theta;
	float sx = 2 * rand_x - 1;
	float sy = 2 * rand_y - 1;
	if (sx == 0.0 && sy == 0.0) {
		return glm::vec2(0.f);
	}
	if (sx >= -sy) {
		if (sx > sy) {
			r = sx;
			if (sy > 0.0) theta = sy / r;
			else          theta = 8.0f + sy / r;
		}
		else {
			r = sy;
			theta = 2.0f - sx / r;
		}
	}
	else {
		if (sx <= sy) {
			r = -sx;
			theta = 4.0f - sy / r;
		}
		else {
			r = -sy;
			theta = 6.0f + sx / r;
		}
	}
	theta *= PI / 4.f;
	return glm::vec2(r * cosf(theta), r * sinf(theta));
}
/**
* Generate PathSegments with rays from the camera through the screen into the
* scene, which is the first bounce of rays.
*
* Antialiasing - add rays for sub-pixel sampling
* motion blur - jitter rays "in time"
* lens effect - jitter ray origin positions based on a lens
*/
__global__ void generateRayFromCamera(Camera cam, int iter, int traceDepth, PathSegment* pathSegments, float* wavelen)
{
	int x = (blockIdx.x * blockDim.x) + threadIdx.x;
	int y = (blockIdx.y * blockDim.y) + threadIdx.y;

	if (x < cam.resolution.x && y < cam.resolution.y) {
		int index = x + (y * cam.resolution.x);
		PathSegment & segment = pathSegments[index];

		segment.ray.origin = cam.position;
		segment.color = glm::vec3(1.0f, 1.0f, 1.0f);
		thrust::default_random_engine rng1 = makeSeededRandomEngine(iter, x, y);
		thrust::default_random_engine rng = makeSeededRandomEngine(iter, x+(cam.resolution.x)*y, 0);
		thrust::uniform_real_distribution<float> u01(-0.5f, 0.5f);
		thrust::uniform_real_distribution<float> u02(0, 1.f);
#if ANTIALIASING == 1
		// TODO: implement antialiasing by jittering the ray
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x+u01(rng)- (float)cam.resolution.x * 0.5f )
			- cam.up * cam.pixelLength.y * ((float)y+ u01(rng) - (float)cam.resolution.y * 0.5f )
			);
#else
		segment.ray.direction = glm::normalize(cam.view
			- cam.right * cam.pixelLength.x * ((float)x - (float)cam.resolution.x * 0.5f)
			- cam.up * cam.pixelLength.y * ((float)y - (float)cam.resolution.y * 0.5f)
		);
#endif
#if DOFTOGGLE == 1
		float rand_x = u01(rng);
		float rand_y = u01(rng);
		float camlenrad = 0.6;
		float focallen = 10;
		glm::vec2 raysampled = camlenrad*ConcentricSampleDisk(rand_x, rand_y);
		glm::vec3 physicallength = segment.ray.origin + glm::abs(focallen / segment.ray.direction.z)*segment.ray.direction;
		segment.ray.origin = segment.ray.origin + raysampled.x*cam.right + raysampled.y*cam.up;
		segment.ray.direction = glm::normalize(physicallength - segment.ray.origin);
#endif
		segment.ray.wavelength = u01(rng1)+0.5f;
		segment.pixelIndex = index;
		segment.remainingBounces = traceDepth;
	}
}

__global__ void ComputeBSDF( int num_paths
	, PathSegment *pathSegments
	, ShadeableIntersection *intersections )
{
	int path_idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (path_idx < num_paths)
	{
		if (intersections[path_idx].materialId == 0)//diffuse?
		{

		}
	}

}

// TODO:
// computeIntersections handles generating ray intersections ONLY.
// Generating new rays is handled in your shader(s).
// Feel free to modify the code below.
__global__ void computeIntersections(
	int depth
	, int num_paths
	, PathSegment * pathSegments
	, Geom * geoms
	, int geoms_size
	, ShadeableIntersection * intersections
	, mesh* meshs
	, Triangle* triangle1
#ifdef TOGGLEKD
	, GPUKDtreeNode* node
	, int node_size
	, int* gputrilst
	, int trisize
	, int* idxchecker
#endif
	)
{
	int path_index = blockIdx.x * blockDim.x + threadIdx.x;

	if (path_index < num_paths)
	{
		PathSegment pathSegment = pathSegments[path_index];

		float t;
		glm::vec3 intersect_point;
		glm::vec3 normal;
		float t_min = FLT_MAX;
		int hit_geom_index = -1;
		bool outside = true;

		bool have_mesh = false;
		glm::vec3 tmp_intersect;
		glm::vec3 tmp_normal;

		// naive parse through global geoms

		for (int i = 0; i < geoms_size; i++)
		{
			Geom & geom = geoms[i];
			have_mesh = false;

			if (geom.type == CUBE)
			{
				t = boxIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == SPHERE)
			{
				t = sphereIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside);
			}
			else if (geom.type == MESH)
			{
				have_mesh = true;
				if (geom.meshid != -1);
				{
#ifdef TOGGLEKD
					bool isTraversed[MAX_NODE_SIZE] = { false };
					mesh & Tempmesh = meshs[geom.meshid];
					glm::vec3 maxbound = Tempmesh.maxbound;
					glm::vec3 minbound = Tempmesh.minbound;
					if (!aabbBoxIntersectlocal(geom, pathSegment.ray, minbound, maxbound))
					{
						t = -1;
						continue;
					}
					bool hitgeom = false;
					float near = -1;
					GPUKDtreeNode* curnode = &node[0];
					int curid = 0;
					float dis = FLT_MAX;
					//idxchecker[0] = 1;
					int count = 0;
					while (curid!=-1)
					{
						curnode = &node[curid];
						bool lefthit = false;
						bool righthit = false;
						if(curnode->leftidx!=-1)
						lefthit= KDtreeintersectBB(pathSegment.ray, node[curnode->leftidx].minB, node[curnode->leftidx].maxB, near);
						if(curnode->rightidx!=-1)
						righthit = KDtreeintersectBB(pathSegment.ray, node[curnode->rightidx].minB, node[curnode->rightidx].maxB, near);
						if (!lefthit&&curnode->leftidx != -1)
						{
							isTraversed[curnode->leftidx] = true;
						}
						if (!righthit&&curnode->rightidx != -1)
						{
							isTraversed[curnode->rightidx] = true;
						}
						while (curnode->leftidx != -1 && isTraversed[curnode->leftidx] == false)
						{

								curid = curnode->leftidx;
								curnode = &node[curid];

						}
						if (!isTraversed[curid])
						{
							isTraversed[curnode->curidx] = true;
							if (curnode->isleafnode)
							{
								int size = curnode->trsize;
								if (size > 0)
								{
									int start = curnode->GPUtriangleidxinLst;
									int end = start + size;
									for (int j = start; j < end; ++j)
									{
										int triidxnow = gputrilst[j];
										t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside, triangle1[triidxnow]);
										dis = t;
										if (t > 0.0f && t_min > t)
										{
											t_min = t;
											hit_geom_index = i;
											intersect_point = tmp_intersect;
											normal = tmp_normal;
										}
									}
								}
							}
						}
						if (curnode->rightidx != -1 && isTraversed[curnode->rightidx] == false)
						{

								curid = curnode->rightidx;
								curnode = &node[curid];

						}
						else
						{
							curid = curnode->parentidx;
							curnode = &node[curid];
						}

						
					}
					/*int startidx, endidx;
					int size = 0;
					bool ishit = KDhit(geom, node, pathSegment.ray, startidx, endidx, gputrilst, size);
					if (ishit)
					{
						for (int j = startidx; j < endidx; ++j)
						{
							Triangle curTri = triangle1[gputrilst[j]];
							t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside, curTri);
							if (t > 0.0f && t_min > t)
							{
								t_min = t;
								hit_geom_index = i;
								intersect_point = tmp_intersect;
								normal = tmp_normal;
							}
						}

					}*/
#else
					mesh & Tempmesh = meshs[geom.meshid];
					glm::vec3 maxbound = Tempmesh.maxbound;
					glm::vec3 minbound = Tempmesh.minbound;
					int startidx = meshs[geom.meshid].TriStartIndex;
					int trisize = meshs[geom.meshid].TriSize;
					if (!aabbBoxIntersectlocal(geom,pathSegment.ray, minbound, maxbound))
					{
						t = -1;
						continue;
					}
					for (int j = startidx; j < trisize + startidx; ++j)
					{
						Triangle & triii = triangle1[j];
						t = triangleIntersectionTest(geom, pathSegment.ray, tmp_intersect, tmp_normal, outside,triii);
						if (t > 0.0f && t_min > t)
						{
							t_min = t;
							hit_geom_index = i;
							intersect_point = tmp_intersect;
							normal = tmp_normal;
						}
					}


#endif
				}
			}
			// TODO: add more intersection tests here... triangle? metaball? CSG?

			// Compute the minimum t from the intersection tests to determine what
			// scene geometry object was hit first.
			if (!have_mesh)
			{
				if (t > 0.0f && t_min > t)
				{
					t_min = t;
					hit_geom_index = i;
					intersect_point = tmp_intersect;
					normal = tmp_normal;
				}
			}
		}

		if (hit_geom_index == -1)
		{
			intersections[path_index].t = -1.0f;
		}
		else
		{
			//The ray hits something
			pathSegments[path_index].it = outside ? 0.f : t_min;
			intersections[path_index].t = t_min;
			intersections[path_index].materialId = geoms[hit_geom_index].materialid;
			intersections[path_index].surfaceNormal = normal;
		}
	}
}

// LOOK: "fake" shader demonstrating what you might do with the info in
// a ShadeableIntersection, as well as how to use thrust's random number
// generator. Observe that since the thrust random number generator basically
// adds "noise" to the iteration, the image should start off noisy and get
// cleaner as more iterations are computed.
//
// Note that this shader does NOT do a BSDF evaluation!
// Your shaders should handle that - this can allow techniques such as
// bump mapping.
__global__ void shadeFakeMaterial (
  int iter
  , int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
	)
{
  int idx = blockIdx.x * blockDim.x + threadIdx.x;
  if (idx < num_paths)
  {
    ShadeableIntersection intersection = shadeableIntersections[idx];
    if (intersection.t > 0.0f) { // if the intersection exists...
      // Set up the RNG
      // LOOK: this is how you use thrust's RNG! Please look at
      // makeSeededRandomEngine as well.
      thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
      thrust::uniform_real_distribution<float> u01(0, 1);
      Material material = materials[intersection.materialId];
      glm::vec3 materialColor = material.color;
      // If the material indicates that the object was a light, "light" the ray
      if (material.emittance > 0.0f) {
        pathSegments[idx].color *= (materialColor * material.emittance);
      }
      // Otherwise, do some pseudo-lighting computation. This is actually more
      // like what you would expect from shading in a rasterizer like OpenGL.
      // TODO: replace this! you should be able to start with basically a one-liner
      else {
        float lightTerm = glm::dot(intersection.surfaceNormal, glm::vec3(0.0f, 1.0f, 0.0f));
        pathSegments[idx].color *= (materialColor * lightTerm) * 0.3f + ((1.0f - intersection.t * 0.02f) * materialColor) * 0.7f;
        pathSegments[idx].color *= u01(rng); // apply some noise because why not
      }
    // If there was no intersection, color the ray black.
    // Lots of renderers use 4 channel color, RGBA, where A = alpha, often
    // used for opacity, in which case they can indicate "no opacity".
    // This can be useful for post-processing and image compositing.
    } else {
      pathSegments[idx].color = glm::vec3(0.0f);
    }
  }
}

__global__ void shadeMaterial(
	int iter
	, int num_paths
	, ShadeableIntersection * shadeableIntersections
	, PathSegment * pathSegments
	, Material * materials
)
{
	int idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < num_paths)
	{
		ShadeableIntersection intersection = shadeableIntersections[idx];
		if (intersection.t > 0.0f) 
		{ // if the intersection exists...
									 // Set up the RNG
									 // LOOK: this is how you use thrust's RNG! Please look at
									 // makeSeededRandomEngine as well.
			thrust::default_random_engine rng = makeSeededRandomEngine(iter, idx, 0);
			thrust::uniform_real_distribution<float> u01(0, 1);
			Material material = materials[intersection.materialId];
			glm::vec3 materialColor = material.color;
			if (pathSegments[idx].remainingBounces > 0)
			{
				scatterRay(pathSegments[idx], intersection.t*pathSegments[idx].ray.direction+pathSegments[idx].ray.origin, intersection.surfaceNormal, materials[intersection.materialId], rng);
			}
		}
		else
		{
#if FULLLIGHT == 0
			pathSegments[idx].color = glm::vec3(0.0f);
#else
			pathSegments[idx].color *= glm::vec3(0.1f,0.1f,0.1f);
#endif
			pathSegments[idx].remainingBounces = 0;
		}
	}
}

// Add the current iteration's output to the overall image
__global__ void finalGather(int nPaths, glm::vec3 * image, PathSegment * iterationPaths)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;

	if (index < nPaths)
	{
		PathSegment iterationPath = iterationPaths[index];
		image[iterationPath.pixelIndex] += iterationPath.color;
	}
}

__global__ void initializechecker(int checknums, int* checker)
{
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < checknums)
	{
		 checker[index] = -1;
	}
}

/**
 * Wrapper for the __global__ call that sets up the kernel calls and does a ton
 * of memory management
 */
void pathtrace(uchar4 *pbo, int frame, int iter) {
    const int traceDepth = hst_scene->state.traceDepth;
    const Camera &cam = hst_scene->state.camera;
    const int pixelcount = cam.resolution.x * cam.resolution.y;

	// 2D block for generating ray from camera
    const dim3 blockSize2d(8, 8);
    const dim3 blocksPerGrid2d(
            (cam.resolution.x + blockSize2d.x - 1) / blockSize2d.x,
            (cam.resolution.y + blockSize2d.y - 1) / blockSize2d.y);

	// 1D block for path tracing
	const int blockSize1d = 128;

	dim3 nums = (hst_scene->KDtreeforGPU.size() + blockSize1d - 1) / blockSize1d;
	initializechecker << <nums, blockSize1d >> >(hst_scene->KDtreeforGPU.size(),dev_idxchecker);
    ///////////////////////////////////////////////////////////////////////////

    // Recap:
    // * Initialize array of path rays (using rays that come out of the camera)
    //   * You can pass the Camera object to that kernel.
    //   * Each path ray must carry at minimum a (ray, color) pair,
    //   * where color starts as the multiplicative identity, white = (1, 1, 1).
    //   * This has already been done for you.
    // * For each depth:
    //   * Compute an intersection in the scene for each path ray.
    //     A very naive version of this has been implemented for you, but feel
    //     free to add more primitives and/or a better algorithm.
    //     Currently, intersection distance is recorded as a parametric distance,
    //     t, or a "distance along the ray." t = -1.0 indicates no intersection.
    //     * Color is attenuated (multiplied) by reflections off of any object
    //   * TODO: Stream compact away all of the terminated paths.
    //     You may use either your implementation or `thrust::remove_if` or its
    //     cousins.
    //     * Note that you can't really use a 2D kernel launch any more - switch
    //       to 1D.
    //   * TODO: Shade the rays that intersected something or didn't bottom out.
    //     That is, color the ray by performing a color computation according
    //     to the shader, then generate a new ray to continue the ray path.
    //     We recommend just updating the ray's PathSegment in place.
    //     Note that this step may come before or after stream compaction,
    //     since some shaders you write may also cause a path to terminate.
    // * Finally, add this iteration's results to the image. This has been done
    //   for you.

    // TODO: perform one iteration of path tracing

	generateRayFromCamera <<<blocksPerGrid2d, blockSize2d >>>(cam, iter, traceDepth, dev_paths,dev_wavelen);
	checkCUDAError("generate camera ray");

	int depth = 0;
	PathSegment* dev_path_end = dev_paths + pixelcount;
	int num_paths = dev_path_end - dev_paths;
	int output_num_paths = num_paths;


	// --- PathSegment Tracing Stage ---
	// Shoot ray into scene, bounce between objects, push shading chunks

	int count = 0;
  bool iterationComplete = false;
	while (!iterationComplete) {

	// clean shading chunks
	cudaMemset(dev_intersections, 0, pixelcount * sizeof(ShadeableIntersection));

	// tracing
	dim3 numblocksPathSegmentTracing = (num_paths + blockSize1d - 1) / blockSize1d;
#if (CACHE ==1&&ANTIALIASING == 0&&DOFTOGGLE == 0)
	if(iter==1&&depth==0)
	{
		computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
			depth
			, num_paths
			, dev_paths
			, dev_geoms
			, hst_scene->geoms.size()
			, dev_intersections
			, dev_meshs
			, dev_triangles
#ifdef TOGGLEKD
			, dev_KDtreenode
			, hst_scene->KDtreeforGPU.size()
			, dev_gputriidxlst
			, hst_scene->triangles.size()
			, dev_idxchecker
#endif
			);
		cudaMemcpy(dev_intersections_cache, dev_intersections, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
	}
	if (iter > 1 && depth == 0)
	{
		cudaMemcpy(dev_intersections, dev_intersections_cache, pixelcount * sizeof(ShadeableIntersection), cudaMemcpyDeviceToDevice);
	}
	else
	{
		if (depth > 0)
		{
			computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
				depth
				, num_paths
				, dev_paths
				, dev_geoms
				, hst_scene->geoms.size()
				, dev_intersections
				, dev_meshs
				, dev_triangles
#ifdef TOGGLEKD
				, dev_KDtreenode
				, hst_scene->KDtreeforGPU.size()
				, dev_gputriidxlst
				, hst_scene->triangles.size()
				, dev_idxchecker
#endif
				);
		}
	}
#else
	computeIntersections << <numblocksPathSegmentTracing, blockSize1d >> > (
		depth
		, num_paths
		, dev_paths
		, dev_geoms
		, hst_scene->geoms.size()
		, dev_intersections
		, dev_meshs
		, dev_triangles
#ifdef TOGGLEKD
		, dev_KDtreenode
		, hst_scene->KDtreeforGPU.size()
		, dev_gputriidxlst
		, hst_scene->triangles.size()
		, dev_idxchecker
#endif
		);
#endif
	checkCUDAError("trace one bounce");
	cudaDeviceSynchronize();
	depth++;
	
	//SORT dev_paths and dev_intersections by material id, don't toggle on unless number of materials is large, or it would slow the program down.
#if SORTBYMATERIAL == 1

	thrust::sort_by_key(thrust::device,dev_intersections, dev_intersections + num_paths, dev_paths, _test_material_());

#endif // SORTBYMATERIAL


	// TODO:
	// --- Shading Stage ---
	// Shade path segments based on intersections and generate new rays by
  // evaluating the BSDF.
  // Start off with just a big kernel that handles all the different
  // materials you have in the scenefile.
  // TODO: compare between directly shading the path segments and shading
  // path segments that have been reshuffled to be contiguous in memory.

  shadeMaterial<<<numblocksPathSegmentTracing, blockSize1d>>> (
    iter,
    num_paths,
    dev_intersections,
    dev_paths,
    dev_materials
  );
  //compaction pathsegments using thrust's partition
#if COMPACTION==1

  PathSegment *_iter_second_begin_ = thrust::partition(thrust::device, dev_paths, dev_paths + num_paths, _test_bounce_());
  num_paths = _iter_second_begin_ - dev_paths;


  if (num_paths > 0)
	  continue;
  else
	  iterationComplete = true;

#endif


#if COMPACTION==1

#elif COMPACTION==0
  count ++ ;
  if(count>8)
	iterationComplete = true;
#endif

   // TODO: should be based off stream compaction results.
	}

  // Assemble this iteration and apply it to the image
	dim3 numBlocksPixels = (pixelcount + blockSize1d - 1) / blockSize1d;
	finalGather<<<numBlocksPixels, blockSize1d>>>(output_num_paths, dev_image, dev_paths);

    ///////////////////////////////////////////////////////////////////////////

    // Send results to OpenGL buffer for rendering
    sendImageToPBO<<<blocksPerGrid2d, blockSize2d>>>(pbo, cam.resolution, iter, dev_image);

    // Retrieve image from GPU
    cudaMemcpy(hst_scene->state.image.data(), dev_image,
            pixelcount * sizeof(glm::vec3), cudaMemcpyDeviceToHost);

    checkCUDAError("pathtrace");
}
