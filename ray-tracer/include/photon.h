#pragma once

#include "owl/common/math/vec.h"
#include "../../externals/cudaKDTree/cukd/data.h"
#include <owl/owl.h>
#include <owl/common/math/vec.h>
#include <owl/common/math/random.h>
#include <cukd/data.h>
#include "../../common/src/mesh.h"

struct Photon {
    // Data for the photon
    float3 pos;
    float3 dir;
    float3 color;
    // Data for KD-tree
    uint8_t quantized_normal[3];
    uint8_t split_dim;
};

struct Photon_traits : public cukd::default_data_traits<float3> {
    using point_t = float3;
    // set to false because "optimized" KD-tree functions are not working
    enum { has_explicit_dim = false };

    static inline __device__ __host__
    float3 get_point(const Photon &data) { return data.pos; }

    static inline __device__ __host__
    float get_coord(const Photon &data, int dim)
    { return cukd::get_coord(get_point(data),dim); }

    // "Optimized" KD-tree functions
    static inline __device__ int get_dim(const Photon &p)
    { return p.split_dim; }

    static inline __device__ void set_dim(Photon &p, int dim)
    { p.split_dim = dim; }
};

/* variables for the ray generation program */
struct RayGenData
{
    uint32_t *fbPtr;
    owl::vec2i  fbSize;
    OptixTraversableHandle world;

    LightSource* lights;
    int numLights;
    Photon* photons;
    int numPhotons;

    int samples_per_pixel;
    int max_ray_depth;

    struct {
        owl::vec3f pos;
        owl::vec3f dir_00; // out-of-screen
        owl::vec3f dir_du; // left-to-right
        owl::vec3f dir_dv; // bottom-to-top
    } camera;
};

/* variables for the miss program */
struct MissProgData
{
    owl::vec3f  sky_colour;
};

typedef owl::LCG<> Random;

struct PerRayData {
    Random random;
    owl::vec3f colour;
    owl::vec3f hit_point;

    struct {
        owl::Ray ray;
        owl::vec3f normal_at_hitpoint;
    } scattered;

    float attenuation;
};
