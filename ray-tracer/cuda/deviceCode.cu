#include "../include/deviceCode.h"
#include "shading.h"

#include "../../common/cuda/helpers.h"

#include <optix_device.h>
#include "owl/RayGen.h"
#include <cukd/knn.h>

#define CONSTANT_LIGHT_FACTOR 0.1f
#define DIFFUSE_SAMPLES 1

using namespace owl;

inline __device__
vec3f tracePath(const RayGenData &self, Ray &ray, PerRayData &prd, int depth) {
  if (depth == 0) return 0.f;

  uint32_t p0, p1;
  packPointer(&prd, p0, p1);
  optixTrace(self.world,
    ray.origin,
    ray.direction,
    EPS,
    INFTY,
    0.f,
    OptixVisibilityMask(255),
    OPTIX_RAY_FLAG_DISABLE_ANYHIT,
    PRIMARY,
    RAY_TYPES_COUNT,
    PRIMARY,
    p0, p1
  );
  if (prd.ray_missed)
    return prd.colour;

  auto albedo = prd.hit_record.material.albedo;
  auto diffuse_brdf = prd.hit_record.material.diffuse / PI;

  // Direct light
  vec3f direct_illumination = 0.f;
  for (int l = 0; l < self.numLights; l++) {
    auto current_light = self.lights[l];

    auto shadow_ray_org = prd.hit_record.hitpoint;
    auto light_dir = current_light.pos - shadow_ray_org;
    auto distance_to_light = norm(light_dir);
    light_dir = normalize(light_dir);

    auto light_dot_norm = dot(light_dir, prd.hit_record.normal_at_hitpoint);
    //if (light_dot_norm < 0.f) continue; // light hits "behind" triangle

    vec3f light_visibility = 0.f;
    uint32_t u0, u1;
    packPointer(&light_visibility, u0, u1);
    optixTrace(
      self.world,
      shadow_ray_org,
      light_dir,
      EPS,
      distance_to_light * (1.f - EPS),
      0.f,
      OptixVisibilityMask(255),
      OPTIX_RAY_FLAG_DISABLE_ANYHIT
      | OPTIX_RAY_FLAG_TERMINATE_ON_FIRST_HIT
      | OPTIX_RAY_FLAG_DISABLE_CLOSESTHIT,
      SHADOW,
      RAY_TYPES_COUNT,
      SHADOW,
      u0, u1
    );

    auto specular_brdf = specularBrdf(prd.hit_record.material.specular,
      light_dir,
      ray.direction,
      prd.hit_record.normal_at_hitpoint);

    direct_illumination += light_visibility
      * CONSTANT_LIGHT_FACTOR
      * static_cast<float>(current_light.power)
      * light_dot_norm
      * (1.f / distance_to_light * distance_to_light)
      * (diffuse_brdf + specular_brdf)
      * current_light.rgb;

  }

  auto direct_term =  albedo * direct_illumination;

  // Specular Reflection
  bool absorbed;
  float coefficient;
  auto out_dir = reflect_or_refract_ray(
    prd.hit_record.material, ray.direction,
    prd.hit_record.normal_at_hitpoint, prd.random,
    absorbed, coefficient
  );

  vec3f specular_term = 0.f;
  // TODO: This fails - OptiX does not support recursion.
  // if (!absorbed) {
  //   auto out_ray = Ray(prd.hit_record.hitpoint, out_dir, EPS, INFTY);
  //
  //   auto reflected_irradiance = tracePath(self, out_ray, prd, depth-1);
  //   specular_term = reflected_irradiance * coefficient;
  // }

  // Caustics
  // TODO - Use caustics map

  vec3f caustics_term = gatherPhotons(prd.hit_record.hitpoint, self.globalPhotons, self.numGlobalPhotons, diffuse_brdf);

  // Diffuse scattering
  // float _dist;
  // auto k_nearest_global = KNearestPhotons(
  //   prd.hit_record.hitpoint, self.photons, self.numPhotons, _dist
  // );
  // vec3f photons_average_dir = 0.f;
  // for (int p = 0; p < K_NEAREST_NEIGHBOURS; p++) {
  //   auto photonID = k_nearest_global.get_pointID(p);
  //   auto photon = self.photons[photonID];
  //
  //   if (isZero(photon.pos)) continue;
  //
  //   photons_average_dir += vec3f(photon.dir);
  // }
  // photons_average_dir = -photons_average_dir / K_NEAREST_NEIGHBOURS;
  auto normal = prd.hit_record.normal_at_hitpoint;
  // vec3f biased_scatter_dir = normalize(photons_average_dir + normal);

  vec3f diffuse_colour = 0.f;
  for (int s = 0; s < DIFFUSE_SAMPLES; s++) {
    PerRayData diffuse_prd;
    diffuse_prd.random.init(prd.random(), prd.random());

    vec3f scattered = normal + randomPointInUnitSphere(diffuse_prd.random);
    if (nearZero(scattered)) scattered = normal;

    uint32_t d0, d1;
    packPointer(&diffuse_prd, d0, d1);

    optixTrace(
      self.world,
      prd.hit_record.hitpoint,
      scattered,
      EPS,
      INFTY,
      0.f,
      OptixVisibilityMask(255),
      OPTIX_RAY_FLAG_DISABLE_ANYHIT,
      DIFFUSE,
      RAY_TYPES_COUNT,
      DIFFUSE,
      d0, d1
    );

    //diffuse_prd = prd;

    if (diffuse_prd.ray_missed) {
      diffuse_colour += diffuse_prd.colour;
      continue;
    }

    auto scattered_albedo = diffuse_prd.hit_record.material.albedo;
    auto scattered_diffuse_brdf = diffuse_prd.hit_record.material.diffuse / PI;

    diffuse_colour += gatherPhotons(
      diffuse_prd.hit_record.hitpoint,
      self.globalPhotons,
      self.numGlobalPhotons,
      scattered_diffuse_brdf
    ) * scattered_albedo;

  }

  vec3f diffuse_term = diffuse_colour / DIFFUSE_SAMPLES;

  // direct_term + specular_term + caustics_term + diffuse_term;
  return caustics_term;
}

OPTIX_RAYGEN_PROGRAM(simpleRayGen)()
{
  const RayGenData &self = owl::getProgramData<RayGenData>();
  const vec2i pixelID = owl::getLaunchIndex();

  PerRayData prd;
  prd.random.init(pixelID.x,pixelID.y);

  if (pixelID.x == 600 && pixelID.y == 330)
  {
    prd.debug = true;
  }

  auto final_colour = vec3f(0.f);
  for (int sample = 0; sample < self.samples_per_pixel; sample++) {
    const auto random_eps = vec2f(prd.random(), prd.random());
    const vec2f screen = (vec2f(pixelID)+random_eps) / vec2f(self.fbSize);

    Ray ray;
    ray.origin
      = self.camera.pos;
    ray.direction
      = normalize(self.camera.dir_00
                  + screen.u * self.camera.dir_du
                  + screen.v * self.camera.dir_dv);

    const auto colour = tracePath(self, ray, prd, self.max_ray_depth);

    final_colour += colour;
  }

  final_colour = final_colour * (1.f / self.samples_per_pixel);

  const int x = pixelID.x;
  const int y = self.fbSize.y - pixelID.y;

  const int fbOfs = x+self.fbSize.x*y;

  self.fbPtr[fbOfs]
    = make_rgba(final_colour);
}

inline __device__ void closestHit() {
  auto &prd = owl::getPRD<PerRayData>();
  const auto self = owl::getProgramData<TrianglesGeomData>();

  prd.hit_record.material = *self.material;

  const vec3f rayDir = optixGetWorldRayDirection();
  const vec3f rayOrg = optixGetWorldRayOrigin();
  const auto tmax = optixGetRayTmax();

  prd.hit_record.hitpoint = rayOrg + rayDir * tmax;

  // Calculate normal at hitpoint and flip if it's pointing
  // in the same direction as the incident ray.
  const auto normal = getPrimitiveNormal(self);
  prd.hit_record.normal_at_hitpoint = (dot(rayDir, normal) < 0.f) ? normal : -normal;

  prd.colour = 0.f;
  prd.ray_missed = false;
}

OPTIX_CLOSEST_HIT_PROGRAM(TriangleMesh)() { closestHit(); }
OPTIX_CLOSEST_HIT_PROGRAM(ScatterDiffuse)() { closestHit(); }

OPTIX_MISS_PROGRAM(miss)()
{
  const MissProgData &self = owl::getProgramData<MissProgData>();

  auto &prd = owl::getPRD<PerRayData>();
  prd.colour = self.sky_colour;
  prd.ray_missed = true;
}

OPTIX_MISS_PROGRAM(shadow)()
{
  // we didn't hit anything, so the light is visible
  vec3f &lightVisbility = getPRD<vec3f>();
  lightVisbility = vec3f(1.f);
}

OPTIX_CLOSEST_HIT_PROGRAM(shadow)() { /* unused */}
OPTIX_ANY_HIT_PROGRAM(shadow)() { /* unused */}
