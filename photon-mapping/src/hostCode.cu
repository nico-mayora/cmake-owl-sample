#include <iostream>
#include <fstream>
#include <iomanip>
// public owl node-graph API
#include "owl/owl.h"
// our device-side data structures
#include "../cuda/deviceCode.h"
// external helper stuff for image output
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../../common/src/assetImporter.h"
#include "../../externals/assimp/code/AssetLib/Q3BSP/Q3BSPFileData.h"
#include "../../externals/stb/stb_image_write.h"
#include "assimp/Importer.hpp"

#define LOG(message)                                            \
  std::cout << OWL_TERMINAL_BLUE;                               \
  std::cout << "#owl.sample(main): " << message << std::endl;   \
  std::cout << OWL_TERMINAL_DEFAULT;
#define LOG_OK(message)                                         \
  std::cout << OWL_TERMINAL_LIGHT_BLUE;                         \
  std::cout << "#owl.sample(main): " << message << std::endl;   \
  std::cout << OWL_TERMINAL_DEFAULT;

/* Image configuration */
auto outFileName = "result.png";

extern "C" char deviceCode_ptx[];

void writeAlivePhotons(const Photon* photons, const std::string& filename) {
  std::ofstream outFile(filename);

  if (!outFile.is_open()) {
    std::cerr << "Error opening file: " << filename << std::endl;
    return;
  }

  outFile << std::fixed << std::setprecision(6);

  for (int i = 0; i < MAX_PHOTONS * MAX_RAY_BOUNCES; i++) {
    auto photon = photons[i];
    if (photon.is_alive) {
      outFile << photon.pos.x << " " << photon.pos.y << " " << photon.pos.z << " "
              << photon.dir.x << " " << photon.dir.y << " " << photon.dir.z << " "
              << photon.color.x << " " << photon.color.y << " " << photon.color.z << "\n";
    }
  }

  outFile.close();
}

void writePhotonsToImage(const Photon* photons, const std::string& filename) {

}

int main(int ac, char **av)
{
  LOG("Starting up...");
  auto *ai_importer = new Assimp::Importer;
  std::string path = "../assets/models/dragon/dragon-box.glb";
  auto world =  assets::import_scene(ai_importer, path);
  double totalPower = 0;
  for (const auto & light : world->light_sources) {
    totalPower += light.power;
  }
  for (auto & light : world->light_sources) {
    light.num_photons = static_cast<int>(light.power / totalPower * MAX_PHOTONS);
  }



  LOG_OK("Loaded world.");

  // create a context on the first device:
  OWLContext context = owlContextCreate(nullptr,1);
  OWLModule module = owlModuleCreate(context, deviceCode_ptx);

  // ##################################################################
  // set up all the *GEOMETRY* graph we want to render
  // ##################################################################

  // -------------------------------------------------------
  // declare geometry type
  // -------------------------------------------------------

  OWLVarDecl trianglesGeomVars[] = {
    { "index",  OWL_BUFPTR, OWL_OFFSETOF(TrianglesGeomData,index)},
    { "vertex", OWL_BUFPTR, OWL_OFFSETOF(TrianglesGeomData,vertex)},
    { "material", OWL_BUFPTR, OWL_OFFSETOF(TrianglesGeomData,material)},
    { nullptr /* Sentinel to mark end-of-list */}
  };

  OWLGeomType trianglesGeomType
    = owlGeomTypeCreate(context,
                        OWL_TRIANGLES,
                        sizeof(TrianglesGeomData),
                        trianglesGeomVars,-1);
  owlGeomTypeSetClosestHit(trianglesGeomType, 0,
                           module,"TriangleMesh");

  // ##################################################################
  // set up all the *GEOMS* we want to run that code on
  // ##################################################################

  LOG("building geometries ...");

  // ------------------------------------------------------------------
  // triangle mesh
  // ------------------------------------------------------------------
  std::vector<OWLGeom> geoms;
  const int numMeshes = static_cast<int>(world->meshes.size());

  for (int meshID=0; meshID<numMeshes; meshID++) {
    auto mesh = world->meshes[meshID];
    std::cout << "ID: " << meshID << " | mat: " << mesh.material->albedo << '\n';
    for (const auto & v : mesh.vertices)
      std::cout << "v " << v << '\n';

    for (const auto & i : mesh.indices)
      std::cout << "v " << i << '\n';


    OWLBuffer vertexBuffer
      = owlDeviceBufferCreate(context,OWL_FLOAT3,mesh.vertices.size(), mesh.vertices.data());
    OWLBuffer indexBuffer
      = owlDeviceBufferCreate(context,OWL_INT3,mesh.indices.size(), mesh.indices.data());
    OWLBuffer materialBuffer
      = owlDeviceBufferCreate(context,OWL_USER_TYPE(Material),1, &mesh.material);

    OWLGeom trianglesGeom
      = owlGeomCreate(context,trianglesGeomType);

    owlTrianglesSetVertices(trianglesGeom,vertexBuffer,
                            mesh.vertices.size(),sizeof(owl::vec3f),0);
    owlTrianglesSetIndices(trianglesGeom,indexBuffer,
                           mesh.indices.size(),sizeof(owl::vec3i),0);

    owlGeomSetBuffer(trianglesGeom,"vertex",vertexBuffer);
    owlGeomSetBuffer(trianglesGeom,"index",indexBuffer);
    owlGeomSetBuffer(trianglesGeom,"material", materialBuffer);

    geoms.push_back(trianglesGeom);
  }

  // ------------------------------------------------------------------
  // the group/accel for that mesh
  // ------------------------------------------------------------------
  OWLGroup trianglesGroup
    = owlTrianglesGeomGroupCreate(context,geoms.size(),geoms.data());
  owlGroupBuildAccel(trianglesGroup);
  OWLGroup owl_world
    = owlInstanceGroupCreate(context,1);
  owlInstanceGroupSetChild(owl_world,0,trianglesGroup);
  owlGroupBuildAccel(owl_world);


  // ##################################################################
  // set miss and raygen program required for SBT
  // ##################################################################

  // -------------------------------------------------------
  // set up miss prog
  // -------------------------------------------------------
  owl::vec3f sky_colour = { 42./255., 169./255., 238./255. };
  OWLVarDecl missProgVars[]
    = {
    { "sky_color", OWL_FLOAT3, OWL_OFFSETOF(MissProgData, sky_color)},
    { /* sentinel to mark end of list */ }
  };

  // ----------- create object  ----------------------------
  OWLMissProg missProg
          = owlMissProgCreate(context,module,"miss",sizeof(MissProgData),
                              missProgVars,-1);

  // ----------- set variables  ----------------------------
  owlMissProgSet3f(missProg,"sky_color", owl3f {42./255., 169./255., 238./255.});

  // -------------------------------------------------------
  // set up ray gen program
  // -------------------------------------------------------
  OWLVarDecl rayGenVars[] = {
          { "photons", OWL_BUFPTR, OWL_OFFSETOF(RayGenData,photons)},
          { "photonsCount", OWL_BUFPTR, OWL_OFFSETOF(RayGenData,photonsCount)},
          { "world", OWL_GROUP, OWL_OFFSETOF(RayGenData,world)},
          { "lightsNum", OWL_INT, OWL_OFFSETOF(RayGenData,lightsNum)},
          { "lightSources", OWL_BUFPTR, OWL_OFFSETOF(RayGenData,lightSources)},
          { /* sentinel to mark end of list */ }
  };

  // ----------- create object  ----------------------------
  OWLRayGen rayGen
          = owlRayGenCreate(context,module,"simpleRayGen",
                            sizeof(RayGenData),
                            rayGenVars,-1);

  // ----------- compute variable values  ------------------
  int numLights = world->light_sources.size();
  auto lightSourcesBuffer = owlDeviceBufferCreate(context,OWL_USER_TYPE(LightSource),numLights, world->light_sources.data());

  // ----------- set variables  ----------------------------
  OWLBuffer photonBuffer = owlHostPinnedBufferCreate(context,OWL_USER_TYPE(Photon),MAX_PHOTONS * MAX_RAY_BOUNCES);

  OWLBuffer photonsCount = owlHostPinnedBufferCreate(context, OWL_INT, 1);
  owlBufferClear(photonsCount);

  owlRayGenSetBuffer(rayGen, "photons", photonBuffer);
  owlRayGenSetBuffer(rayGen, "photonsCount", photonsCount);
  owlRayGenSetGroup(rayGen, "world", owl_world);
  owlRayGenSet1i(rayGen, "lightsNum", numLights);
  owlRayGenSetBuffer(rayGen, "lightSources", lightSourcesBuffer);

  // ##################################################################
  // build *SBT* required to trace the groups
  // ##################################################################
  owlBuildPrograms(context);
  owlBuildPipeline(context);
  owlBuildSBT(context);

  // ##################################################################
  // now that everything is ready: launch it ....
  // ##################################################################

  LOG("launching ...");
  owlRayGenLaunch2D(rayGen,MAX_PHOTONS,1);

  LOG("done with launch, writing picture ...");
  // for host pinned mem it doesn't matter which device we query...
  auto *fb = static_cast<const Photon*>(owlBufferGetPointer(photonBuffer, 0));

  std::cout << *(int*)owlBufferGetPointer(photonsCount, 0);

  assert(fb);

  writeAlivePhotons(fb, "photons.txt");

  LOG_OK("written rendered frame buffer to file "<<outFileName);
  // ##################################################################
  // and finally, clean up
  // ##################################################################

  LOG("destroying devicegroup ...");
  owlContextDestroy(context);

  LOG_OK("seems all went OK; app is done, this should be the last output ...");
  return 0;
}
