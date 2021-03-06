#ifndef _PARTICLES_KERNEL_IMPL_CUH
#define _PARTICLES_KERNEL_IMPL_CUH

#include "sph_kernel.cuh"

#include "kernels_impl.cuh"

#include <cuda_runtime.h>
#include <cuda_gl_interop.h>

#include <cuda_helpers/helper_cuda.h>
#include <cuda_helpers/helper_cuda_gl.h>
#include <cuda_helpers/helper_functions.h>
#include <cuda_helpers/helper_math.h>

#include <stdio.h>
#include <math.h>

#include <math_constants.h>
#include <float.h>

#if USE_TEX
// textures for particle position and velocity
texture<SVec4, 1, cudaReadModeElementType> oldPosTex;
texture<SVec4, 1, cudaReadModeElementType> oldVelTex;
texture<SReal, 1, cudaReadModeElementType> oldDensTex;
texture<SReal, 1, cudaReadModeElementType> oldPresTex;
texture<SVec4, 1, cudaReadModeElementType> oldForcesTex;
texture<SVec4, 1, cudaReadModeElementType> oldColTex;

//texture for iisph
texture<SReal, 1, cudaReadModeElementType> oldDensAdvTex;
texture<SReal, 1, cudaReadModeElementType> oldDensCorrTex;
texture<SReal, 1, cudaReadModeElementType> oldP_lTex;
texture<SReal, 1, cudaReadModeElementType> oldPreviousPTex;
texture<SReal, 1, cudaReadModeElementType> oldAiiTex;

texture<SVec4, 1, cudaReadModeElementType> oldVelAdvTex;
texture<SVec4, 1, cudaReadModeElementType> oldForcesAdvTex;
texture<SVec4, 1, cudaReadModeElementType> oldForcesPTex;
texture<SVec4, 1, cudaReadModeElementType> oldDiiFluidTex;
texture<SVec4, 1, cudaReadModeElementType> oldDiiBoundaryTex;
texture<SVec4, 1, cudaReadModeElementType> oldSumDijTex;
texture<SVec4, 1, cudaReadModeElementType> oldNormalTex;

//texture for pcisph
texture<SReal, 1,cudaReadModeElementType> oldRhoAdvPciTex;
texture<SVec4, 1,cudaReadModeElementType> oldVelAdvPciTex;
texture<SVec4, 1,cudaReadModeElementType> oldForcesAdvPciTex;
texture<SVec4, 1,cudaReadModeElementType> oldForcesPresPciTex;
texture<SVec4, 1,cudaReadModeElementType> oldPosAdvPciTex;

//grid textures
texture<SUint, 1, cudaReadModeElementType> gridParticleHashTex;
texture<SUint, 1, cudaReadModeElementType> cellStartTex;
texture<SUint, 1, cudaReadModeElementType> cellEndTex;

//boundaries
texture<SVec4, 1, cudaReadModeElementType> oldBoundaryPosTex;
texture<SReal, 1, cudaReadModeElementType> oldBoundaryVbiTex;
texture<SUint, 1, cudaReadModeElementType> gridBoundaryHashTex;
texture<SUint, 1, cudaReadModeElementType> cellBoundaryStartTex;
texture<SUint, 1, cudaReadModeElementType> cellBoundaryEndTex;
#endif

__constant__ SphSimParams sph_params;

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
struct integrate_functor //used only for state equation SPH
{
    SReal deltaTime;

    __host__ __device__ integrate_functor(SReal delta_time) : deltaTime(delta_time) {}

    template <typename Tuple>
    __device__ void operator()(Tuple t)
    {
		SReal dt = sph_params.timestep;
		SReal m1 = sph_params.particleMass;

        volatile SVec4 posData = thrust::get<0>(t);
        volatile SVec4 velData = thrust::get<1>(t);
        volatile SVec4 forData = thrust::get<2>(t);

        SVec3 pos = make_SVec3(posData.x, posData.y, posData.z);
        SVec3 vel = make_SVec3(velData.x, velData.y, velData.z);
        SVec3 frc = make_SVec3(forData.x, forData.y, forData.z);

		SVec3 accel = dt*frc/m1;

		vel = vel+accel;
		pos = pos + dt*vel;

        // store new position and velocity
        thrust::get<0>(t) = make_SVec4(pos, posData.w);
        thrust::get<1>(t) = make_SVec4(vel, velData.w);
    }
};

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ int3 calcGridPos(SVec3 p)
{
    int3 gridPos;
    gridPos.x = floor((p.x - sph_params.worldOrigin.x) / sph_params.cellSize.x);
    gridPos.y = floor((p.y - sph_params.worldOrigin.y) / sph_params.cellSize.y);
    gridPos.z = floor((p.z - sph_params.worldOrigin.z) / sph_params.cellSize.z);

    return gridPos;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SUint calcGridHash(int3 gridPos)
{
    gridPos.x = gridPos.x & (sph_params.gridSize.x-1);  // wrap grid, assumes size is power of 2
    gridPos.y = gridPos.y & (sph_params.gridSize.y-1);
    gridPos.z = gridPos.z & (sph_params.gridSize.z-1);

    return __umul24(__umul24(gridPos.z, sph_params.gridSize.y), sph_params.gridSize.x) + __umul24(gridPos.y, sph_params.gridSize.x) + gridPos.x;
}

__global__ void calcHashD(SUint   *gridParticleHash,  // output
               SUint   *gridParticleIndex, // output
               SVec4 *pos,               // input: positions
               SUint    numParticles)
{
    SUint index = blockIdx.x*blockDim.x + threadIdx.x;

    if (index >= numParticles) return;

    volatile SVec4 p = pos[index];

    // get address in grid
    int3 gridPos = calcGridPos(make_SVec3(p.x, p.y, p.z));
    SUint hash = calcGridHash(gridPos);

    // store grid hash and particle index
    gridParticleHash[index] = hash;
    gridParticleIndex[index] = index;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void reorderDataAndFindCellStartDBoundary(SUint *cellBoundaryStart,
												SUint * cellBoundaryEnd,
												SVec4* sortedBoundaryPos,
												SReal* sortedBoundaryVbi,
												SUint *gridBoundaryHash,
												SUint *gridBoundaryIndex,
												SVec4* oldBoundaryPos,
												SReal*  oldBoundaryVbi,
												SUint numBoundaries)
{
	extern __shared__ SUint sharedHash[];
	SUint index = blockIdx.x * blockDim.x + threadIdx.x;

	SUint hash;

	if (index < numBoundaries) 
	{
		hash = gridBoundaryHash[index];

		sharedHash[threadIdx.x+1] = hash;

		if (index > 0 && threadIdx.x == 0)
		{
			// first thread in block must load neighbor particle hash
			sharedHash[0] = gridBoundaryHash[index-1];
		}
	}

	__syncthreads();


	if (index < numBoundaries)
	{
		if (index == 0 || hash != sharedHash[threadIdx.x])
		{
			cellBoundaryStart[hash] = index;

			if (index > 0)
				cellBoundaryEnd[sharedHash[threadIdx.x]] = index;
		}

		if (index == numBoundaries - 1)
		{
			cellBoundaryEnd[hash] = index + 1;
		}

		// Now use the sorted index to reorder the pos and vel data
		SUint sortedIndex = gridBoundaryIndex[index];

		SVec4 pos = FETCH(oldBoundaryPos, sortedIndex);       // macro does either global read or texture fetch
		SReal vbi = FETCH(oldBoundaryVbi, sortedIndex);       // see particles_kernel.cuh
		
		oldBoundaryPos[index] = pos;
		oldBoundaryVbi[index] = vbi;
	}
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void reorderDataAndFindCellStartD(SUint   *cellStart,        // output: cell start index
                                  SUint   *cellEnd,          // output: cell end index
                                  SVec4 *sortedPos,        // output: sorted positions
                                  SVec4 *sortedVel,        // output: sorted velocities
                                  SReal *sortedDens,       // output: sorted densities
                                  SReal *sortedPres,       // output: sorted pressures
                                  SVec4 *sortedForces,     // output: sorted forces
                                  SVec4 *sortedCol,        // output: sorted colors
                                  SUint   *gridParticleHash, // input: sorted grid hashes
                                  SUint   *gridParticleIndex,// input: sorted particle indices
                                  SVec4 *oldPos,           // input: sorted position array
                                  SVec4 *oldVel,           // input: sorted velocity array
                                  SReal *oldDens,          // input: sorted density  array
                                  SReal *oldPres,          // input: sorted pressure array
                                  SVec4 *oldForces,        // input: sorted forces   array
                                  SVec4 *oldCol,           // input: sorted color    array
                                  SUint    numParticles)
{
    extern __shared__ SUint sharedHash[];    // blockSize + 1 elements
    SUint index = blockIdx.x*blockDim.x + threadIdx.x;

    SUint hash;

	// handle case when no. of particles not multiple of block size
	if (index < numParticles)
	{
		hash = gridParticleHash[index];

		// Load hash data into shared memory so that we can look
		// at neighboring particle's hash value without loading
		// two hash values per thread
		sharedHash[threadIdx.x+1] = hash;

		if (index > 0 && threadIdx.x == 0)
		{
			// first thread in block must load neighbor particle hash
			sharedHash[0] = gridParticleHash[index-1];
		}
	}
	__syncthreads();

	if (index < numParticles)
	{
        //// If this particle has a different cell index to the previous
        //// particle then it must be the first particle in the cell,
        //// so store the index of this particle in the cell.
        //// As it isn't the first particle, it must also be the cell end of
        //// the previous particle's cell
		
		if (index == 0 || hash != sharedHash[threadIdx.x])
		{
			cellStart[hash] = index;

			if (index > 0)
				cellEnd[sharedHash[threadIdx.x]] = index;
		}

		if (index == numParticles - 1)
		{
			cellEnd[hash] = index + 1;
		}

		// Now use the sorted index to reorder the pos and vel data
		SUint sortedIndex = gridParticleIndex[index];
		SVec4 pos = FETCH(oldPos, sortedIndex);       // macro does either global read or texture fetch
		SVec4 vel = FETCH(oldVel, sortedIndex);       // see particles_kernel.cuh
		SReal pressure = FETCH(oldPres, sortedIndex);       // see particles_kernel.cuh
		sortedVel[index] = vel;
		sortedPos[index] = pos;
		sortedPres[index] = pressure;
	}
}

/**********************************************************************
*                      COMPUTE DENSITY PRESSURE                      *
**********************************************************************/

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal computeCellDensity(int *nb, int3 gridPos, SUint index, SVec3 pos, SVec4 *oldPos, SUint *cellStart, SUint *cellEnd,
		SReal ir, SReal kp, SReal rd, SReal pm)
{
    const SUint gridHash = calcGridHash(gridPos);
	const SUint startIndex = FETCH(cellStart, gridHash);

	SReal dens = 0.0;
	const SVec3 pos1 = make_SVec3(pos.x, pos.y, pos.z);

	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);

        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
				const SVec3 p1p2 = pos1 - pos2;
				if(length(p1p2) < ir)
				{
#if KERNEL_SET == MULLER
					dens += (pm * Wdefault(p1p2, ir, kp));
#elif KERNEL_SET == MONAGHAN
					dens += (pm * Wmonaghan(p1p2, ir));
#endif
				}
			}
		}
	}
	return dens;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal computeBoundaryCellDensity(int3 gridPos, SVec3 pos, SUint* gridBoundaryIndex, SVec4* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd,
		SReal ir, SReal kp, SReal rd, SReal pm)
{
	const SUint gridHash = calcGridHash(gridPos);
	const SUint startIndex = FETCH(cellBoundaryStart, gridHash);

	SReal dens = 0.0;
	const SVec3 pos1 = pos;

	if (startIndex != 0xffffffff) 
	{
		const SUint endIndex = FETCH(cellBoundaryEnd, gridHash);

		for (unsigned  int j = startIndex; j < endIndex; ++j)
		{
			const SUint originalIndex = gridBoundaryIndex[j];

			const SVec3 pos2 = make_SVec3(FETCH(oldBoundaryPos, originalIndex));
			const SReal  vbi  = FETCH(oldBoundaryVbi, originalIndex);
			const SVec3 p1p2 = pos1 - pos2;

			if (length(p1p2) < ir) 
			{
				const SReal psi = rd* vbi;
#if KERNEL_SET == MULLER
					dens += ( psi * Wdefault(p1p2, ir, kp) );
#elif KERNEL_SET == MONAGHAN
					dens += ( psi * Wmonaghan(p1p2, ir) );
#endif
			}
		}
	}

	return dens;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void computeDensityPressure(
              SVec4 *oldPos,               // input: sorted positions
              SVec4 *oldVel,               // input: sorted velocities
              SReal *oldDens,               // input: sorted velocities
              SReal *oldPres,               // input: sorted velocities
              SVec4 *oldForces,            // input: sorted velocities
              SVec4 *oldCol,               // input: sorted velocities
			  SVec4 *oldBoundaryPos,
			  SReal  *oldBoundaryVbi,
              SUint   *gridParticleIndex,    // input: sorted particle indices
              SUint   *cellStart,
              SUint   *cellEnd,
			  SUint   *gridBoundaryIndex,
			  SUint   *cellBoundaryStart,
			  SUint   *cellBoundaryEnd,
              SUint    numParticles)
{
    const SUint index = blockIdx.x*blockDim.x + threadIdx.x;

    if (index >= numParticles) return;

	const SUint originalIndex = gridParticleIndex[index];

    // read particle data from sorted arrays
    const SVec3 pos = make_SVec3(FETCH(oldPos, originalIndex));
    const SVec3 vel = make_SVec3(FETCH(oldVel, originalIndex));

    // get address in grid
    const int3 gridPos = calcGridPos(pos);

    // examine neighbouring cells
    SReal dens = 0.0;
	int nbVois = 0;

	//const memory access
	const SReal ir = sph_params.interactionRadius;
	const SReal kp = sph_params.kpoly;
	const SReal rd = sph_params.restDensity;
	const SReal pm = sph_params.particleMass;

#if KERNEL_SET == MULLER
	dens += pm * Wdefault(make_SVec3(0.0, 0.0, 0.0), ir, kp);
#elif KERNEL_SET == MONAGHAN
	dens += pm * Wmonaghan(make_SVec3(0.0, 0.0, 0.0), ir);
#endif

	//compute density
    for (int z=-1; z<=1; z++)
    {
        for (int y=-1; y<=1; y++)
        {
            for (int x=-1; x<=1; x++)
            {
                const int3 neighbourPos = gridPos + make_int3(x, y, z);
				dens += computeCellDensity(&nbVois, neighbourPos, originalIndex, pos, oldPos, cellStart, cellEnd, ir, kp, rd, pm);
				dens += computeBoundaryCellDensity(neighbourPos, pos, gridBoundaryIndex, oldBoundaryPos, oldBoundaryVbi, cellBoundaryStart, cellBoundaryEnd, ir, kp, rd, pm);
            }
        }
    } 
	
	//compute Pressure
	const SReal pressure = sph_params.gasStiffness * (powf(dens/sph_params.restDensity, 7) -1);

    /******************
	*  GLOBAL WRITE  *
	******************/
    oldDens[originalIndex] = dens;
    oldPres[originalIndex] = pressure;
}

/**********************************************************************
*                           COMPUTE FORCES                           *
**********************************************************************/

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ void computeCellForces(
		SVec3     *fpres,
		SVec3     *fvisc,
		SVec3     *fsurf,
		SVec3     *fbound,
		int3       gridPos,
		unsigned   int index,
		SVec3     pos,
		SVec3     vel,
		SReal      dens,
		SReal      pres,
		SVec4*    oldPos,
		SReal      *oldDens,
		SReal*     oldPres,
		SVec4*    oldVel,
		SUint* gridBoundaryIndex,
		SVec4*    oldBoundaryPos,
		SReal*     oldBoundaryVbi,
		SUint *cellStart,
		SUint *cellEnd,
		SUint *cellBoundaryStart,
		SUint *cellBoundaryEnd)
{
    const SUint gridHash = calcGridHash(gridPos);
	SUint startIndex = FETCH(cellStart, gridHash);

	const SVec3 pos1 = make_SVec3(pos.x, pos.y, pos.z);
	const SVec3 vel1 = make_SVec3(vel.x, vel.y, vel.z);

	SVec3 forces = make_SVec3(0.0, 0.0, 0.0);
	SVec3 forces_pres = make_SVec3(0.0, 0.0, 0.0);
	SVec3 forces_visc = make_SVec3(0.0, 0.0, 0.0);

	const SReal pm = sph_params.particleMass;
	const SReal m2 = sph_params.particleMass;
	const SReal ir = sph_params.interactionRadius;
	const SReal kp = sph_params.kpoly;
	const SReal kappa = sph_params.surfaceTension;

	const SReal kprg = sph_params.kpress_grad;
	const SReal kvg  = sph_params.kvisc_grad;
	const SReal kvd  = sph_params.kvisc_denum;

	/*const SReal ksurf1 = sph_params.ksurf1;*/
	/*const SReal ksurf2 = sph_params.ksurf2;*/

	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);

        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
				const SReal dens2 = FETCH(oldDens, j);
				const SReal pres2 = FETCH(oldPres, j);
				const SVec3 vel2 = make_SVec3(FETCH(oldVel, j));

				const SVec3 p1p2 = pos1-pos2;



				if (length(p1p2) < ir)
				{

					const SReal diameter = 2.0 * sph_params.particleRadius;
					const SReal diameter2 = diameter*diameter;

					const SVec3 v1v2 = vel1-vel2;

					const SReal d1sq = dens*dens;
					const SReal d2sq = dens2*dens2;
#if KERNEL_SET == MONAGHAN
					const SVec3 kpressure_grad = Wmonaghan_grad(p1p2, ir);
					const SVec3 kvisco_grad = kpressure_grad;
					const SReal kernel = Wmonaghan(p1p2, ir);
					const SReal kernel_diameter = Wmonaghan(make_SVec3(diameter, 0.0, 0.0), ir);
#elif KERNEL_SET == MULLER
					const SVec3 kpressure_grad = Wpressure_grad(p1p2, ir, kprg);
					const SVec3 kvisco_grad = Wviscosity_grad(p1p2, ir, kvg, kvd);
					const SReal kernel = Wdefault(p1p2, ir, kp);
					const SReal kernel_diameter = Wdefault(make_SVec3(diameter, 0.0, 0.0), ir, kp);
#endif

					//pressure
					*fpres = *fpres + (m2 * ( pres/d1sq + pres2/d2sq ) *kpressure_grad);

					//viscosity
					const SReal a = dot(p1p2, kvisco_grad);
					const SReal b = dot(p1p2,p1p2) + 0.01f*(ir*ir);
					*fvisc = *fvisc + (m2/dens2  * v1v2 * (a/b));
					
#if USE_SURFACE_TENSION == 1
					//tension surface becker
					SVec3 ai = make_SVec3(0.0, 0.0, 0.0);
					const SReal r2 = dot(p1p2, p1p2);

					if (r2 > diameter2)
						ai = ai - (kappa / pm * pm * p1p2 * kernel);
					else
						ai = ai - (kappa / pm * pm * p1p2 * kernel_diameter);

					*fsurf = *fsurf + ai;
#endif
				}
			}
		}
	}

	//start again with boundaries
	startIndex = FETCH(cellBoundaryStart, gridHash);
	SVec3 forces_boundaries = make_SVec3(0.0, 0.0, 0.0);

	//friction nu
	const SReal epsilon = 0.01;
	const SReal beta = sph_params.beta;
	const SReal rd = sph_params.restDensity;

	if (startIndex != 0xffffffff)
	{
		const SUint endIndex = FETCH(cellBoundaryEnd, gridHash);

		//loop over rigid boundary particles
        for (SUint j=startIndex; j<endIndex; j++)
		{
			const SUint originalIndex = gridBoundaryIndex[j];

			//boundary data
			const SReal vbi  = FETCH(oldBoundaryVbi, originalIndex);
			const SVec3 vpos= make_SVec3(FETCH(oldBoundaryPos, originalIndex));
			const SReal psi = (rd*vbi);

			//neighbor comparison
			const SVec3 p1p2 = pos1 - vpos;
			const SVec3 v1v2 = vel1;
			const SReal mdot = max(dot(v1v2, p1p2), 0.0);
			const SReal denum = (length(p1p2)*length(p1p2)) + epsilon*ir*ir;

#if KERNEL_SET == MONAGHAN
			const SReal kernel = Wmonaghan(p1p2, ir);
			const SVec3 grad   = Wmonaghan_grad(p1p2, ir);
			
#elif KERNEL_SET == MULLER
			const SReal kernel = Wdefault(p1p2, ir, sph_params.kpoly);
			const SVec3 grad   = Wdefault_grad(p1p2, ir, sph_params.kpoly_grad);
#endif

			//adhesion
			*fbound = *fbound + (beta * psi * p1p2 * kernel);

			//pressure
			*fpres  = *fpres + ( -pm * psi * (pres/(dens*dens)) * grad );

			//friction
			const SReal nu = (sph_params.viscosity * ir * sph_params.soundSpeed)/(dens*dens);
			const SReal nom= fmax(dot(v1v2, p1p2),0);
			const SReal denom= dot(p1p2/length(p1p2), p1p2/length(p1p2)) + epsilon *ir * ir;
			const SReal Pij = -nu * (nom/denom);
			*fvisc = *fvisc - ( pm * psi * Pij * grad );
		}
	}
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__
void computeForces(
              SVec4       * oldPos,               
              SVec4       * oldVel,              
              SReal        * oldDens,            
              SReal        * oldPres,           
              SVec4       * oldForces,        
              SVec4       * oldCol,          
			  SUint * gridBoundaryIndex,
			  SVec4       * oldBoundaryPos,
			  SReal        * oldBoundaryVbi,
              SUint * gridParticleIndex, 
              SUint * cellStart,
              SUint * cellEnd,
			  SUint * cellBoundaryStart,
			  SUint * cellBoundaryEnd,
              SUint    numParticles)
{
    const SUint index = blockIdx.x*blockDim.x + threadIdx.x;

    if (index >= numParticles) return;

	const SUint originalIndex = gridParticleIndex[index];

    // read particle data from sorted arrays
    const SVec3 pos = make_SVec3(FETCH(oldPos, originalIndex));
    const SVec3 vel = make_SVec3(FETCH(oldVel, originalIndex));
	const SReal dens = FETCH(oldDens, originalIndex);
	const SReal pres = FETCH(oldPres, originalIndex);

	const SReal m1 = sph_params.particleMass;

	//grid address
    const int3 gridPos = calcGridPos(pos);

	//accumulators
	SVec3 fpres = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fvisc = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fsurf = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fbound= make_SVec3(0.0, 0.0, 0.0);

	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				//a optimiser !!!
				computeCellForces(&fpres, &fvisc, &fsurf, &fbound, neighbourPos, originalIndex, pos, vel, dens, pres, oldPos, oldDens, oldPres, oldVel, gridBoundaryIndex, oldBoundaryPos, oldBoundaryVbi, cellStart, cellEnd, cellBoundaryStart, cellBoundaryEnd);
			}
		}
	}

	//finishing gradient and laplacian computations
	fpres = fpres * dens;
	fvisc = fvisc * 2.0;
	/*fsurf = -(sph_params.surfaceTension/m1) * fsurf;*/

	//computing forces
	fpres = fpres * -(m1 / dens);
	fvisc = fvisc * (m1*sph_params.viscosity);

	//total force
	SVec3 f = fpres + fvisc + (sph_params.gravity*m1) + fsurf + fbound;
	SVec4 res = make_SVec4(f.x, f.y, f.z, 0);

	/******************
	*  GLOBAL WRITE  *
	******************/
	oldForces[originalIndex] = res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  

/***********
*  IISPH  *
***********/
__device__ SVec3 computeDisplacementFactorCell(SReal dens, SReal mj, int3 gridPos, SVec3 pos, SVec4* oldPos, SUint index, SUint* cellStart, SUint* cellEnd,
		SReal ir, SReal kp, SReal rd, SReal pm)
{
	const SUint gridHash = calcGridHash(gridPos);
	const SUint startIndex = FETCH(cellStart, gridHash);

	SVec3 res  = make_SVec3(0.0, 0.0, 0.0);
	const SVec3 pos1 = make_SVec3(pos.x, pos.y, pos.z);

	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);

		const SReal dt = sph_params.timestep;

        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
				const SVec3 p1p2 = pos1 - pos2;
				const SReal kpg = sph_params.kpoly_grad;

				if(length(p1p2) < ir)
				{
					SVec3 grad;
#if KERNEL_SET == MONAGHAN
					grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
					grad = Wdefault_grad(p1p2, ir, kpg);
#endif
					res = res - ( (pm/(dens*dens)) * grad /** (dt*dt)*/ );
				}
			}
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SVec3 computeDisplacementFactorBoundaryCell(SReal dens, SReal mj, int3 gridPos, SVec3 pos, SVec4* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd,
		SReal ir, SReal kpg, SReal rd, SReal pm, SReal dt)
{
	const SUint gridHash = calcGridHash(gridPos);
	const SUint startIndex = FETCH(cellBoundaryStart, gridHash);

	SVec3 res  = make_SVec3(0.0, 0.0, 0.0);
	const SVec3 pos1 = make_SVec3(pos.x, pos.y, pos.z);

	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellBoundaryEnd, gridHash);
		const SReal dt = sph_params.timestep;

        for (SUint j=startIndex; j<endIndex; j++)
		{
			const SVec3 pos2 = make_SVec3(FETCH(oldBoundaryPos, j));
			const SReal  vbi = FETCH(oldBoundaryVbi, j);
			const SVec3 p1p2 = pos1 - pos2;

			const SReal psi  = rd*vbi;
			if(length(p1p2) < ir)
			{
				SVec3 grad;
#if KERNEL_SET == MONAGHAN
					grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
					grad = Wdefault_grad(p1p2, ir, kpg);
#endif
				res = res - ( (psi/(dens*dens)) * grad /** (dt*dt)*/ );
			}
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void computeIisphDensity(
	SVec4                      * oldPos,
	SVec4                      * oldVel,
	SReal                       * oldDens,
	SReal                       * oldPres,
	SVec4                      * oldForces,
	SVec4                      * oldCol,
	SUint                * cellStart,
	SUint                * cellEnd,
	SUint                * gridParticleIndex,
	SVec4                      * oldBoundaryPos,
	SReal                       * oldBoundaryVbi,
	SUint                * cellBoundaryStart,
	SUint                * cellBoundaryEnd,
	SUint                * gridBoundaryIndex,
	SReal                       * oldDensAdv,
	SReal                       * oldDensCorr,
	SReal                       * oldP_l,
	SReal                       * oldPreviousP,
	SReal                       * oldAii,
	SVec4                      * oldVelAdv,
	SVec4                      * oldForcesAdv,
	SVec4                      * oldForcesP,
	SVec4                      * oldDiiFluid,
	SVec4                      * oldDiiBoundary,
	SVec4                      * oldSumDij,
	SVec4                      * oldNormal,
	SUint numParticles,
	SUint numBoundaries,
	SUint numCells
)
{
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];
	
	//global memory reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 vel1 = make_SVec3(FETCH(oldVel, originalIndex));
	
	//const memory reads
	const SReal kp = sph_params.kpoly;
	const SReal pm = sph_params.particleMass;
	const SReal ir = sph_params.interactionRadius;
	const SReal rd = sph_params.restDensity;

	//grid computations
    const int3 gridPos = calcGridPos(pos1);
	
	/*********************
	*  COMPUTE DENSITY  *
	*********************/
	SReal dens = 0.0;
	int nb = 0;

#if KERNEL_SET == MULLER
	dens += pm * Wdefault(make_SVec3(0.0, 0.0, 0.0), ir, kp);
#elif KERNEL_SET == MONAGHAN
	dens += pm * Wmonaghan(make_SVec3(0.0, 0.0, 0.0), ir);
#endif

	//loop over each neighbor cell
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				dens += computeCellDensity(&nb, neighbourPos, originalIndex, pos1, oldPos, cellStart, cellEnd, ir, kp, rd, pm);
				dens += computeBoundaryCellDensity(neighbourPos, pos1, gridBoundaryIndex, oldBoundaryPos, oldBoundaryVbi, cellBoundaryStart, cellBoundaryEnd, ir, kp, rd, pm);
			}
		}
	}

	oldDens[originalIndex] = dens;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void computeDisplacementFactor(
	SVec4                       * oldPos,
	SVec4                       * oldVel,
	SReal                       * oldDens,
	SReal                       * oldPres,
	SVec4                       * oldForces,
	SVec4                       * oldCol,
	SUint                * cellStart,
	SUint                * cellEnd,
	SUint                * gridParticleIndex,
	SVec4                       * oldBoundaryPos,
	SReal                       * oldBoundaryVbi,
	SUint                * cellBoundaryStart,
	SUint                * cellBoundaryEnd,
	SUint                * gridBoundaryIndex,
	SReal                       * oldDensAdv,
	SReal                       * oldDensCorr,
	SReal                       * oldP_l,
	SReal                       * oldPreviousP,
	SReal                       * oldAii,
	SVec4                       * oldVelAdv,
	SVec4                       * oldForcesAdv,
	SVec4                       * oldForcesP,
	SVec4                       * oldDiiFluid,
	SVec4                       * oldDiiBoundary,
	SVec4                       * oldSumDij,
	SVec4                       * oldNormal,
	SUint numParticles,
	SUint numBoundaries,
	SUint numCells)
{
	/****************************
	*  COMPUTE PARTICLE INDEX  *
	****************************/
    const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];
	
	//global memory reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 vel1 = make_SVec3(FETCH(oldVel, originalIndex));
	const SReal pres = 0.0; //useless, just to reuse computeCellForces below
	const SReal dens = FETCH(oldDens, originalIndex);

	//const memory reads
	const SReal kpg= sph_params.kpoly_grad;
	const SReal pm = sph_params.particleMass;
	const SReal ir = sph_params.interactionRadius;
	const SReal rd = sph_params.restDensity;
	const SReal dt = sph_params.timestep;

	//grid computations
    const int3 gridPos = calcGridPos(pos1);
	
	/***********************
	*  PREDICT ADVECTION  *
	***********************/
	SVec3 fvisc = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fsurf = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fgrav = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fbound= make_SVec3(0.0, 0.0, 0.0);
	SVec3 fpres = make_SVec3(0.0, 0.0, 0.0); //ignored here, just to reuse computeCellForces

	//loop over neighbor cells
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				computeCellForces(&fpres, &fvisc, &fsurf, &fbound, neighbourPos, originalIndex, pos1, vel1, dens, pres, oldPos, oldDens, oldPres, oldVel, gridBoundaryIndex, oldBoundaryPos, oldBoundaryVbi, cellStart, cellEnd, cellBoundaryStart, cellBoundaryEnd);
			}
		}
	}

	//end force computation
	fvisc = 2.0 * fvisc;
	fvisc = (pm*sph_params.viscosity) * fvisc;
	fgrav =  pm*sph_params.gravity;

	/*********************************************
	*  COMPUTE AND STORE FORCE_ADV and VEL_ADV  *
	*********************************************/
	SVec3 force_adv             = fvisc + fsurf + fbound + fgrav;
	SVec3 vel_adv               = vel1 + dt*(force_adv/pm);
	oldForcesAdv[originalIndex] = make_SVec4(force_adv.x, force_adv.y, force_adv.z, 0.0);
	oldVelAdv[originalIndex]    = make_SVec4(vel_adv.x, vel_adv.y, vel_adv.z, 0.0);

	/*****************
	*  COMPUTE dii  *
	*****************/
	SVec3 displacement_factor_fluid    = make_SVec3(0.0, 0.0, 0.0);
	SVec3 displacement_factor_boundary = make_SVec3(0.0, 0.0, 0.0);
	for (int z=-1; z<=1; z++)
    {
        for (int y=-1; y<=1; y++)
        {
            for (int x=-1; x<=1; x++)
            {
                const int3 neighbourPos      = gridPos + make_int3(x, y, z);
				displacement_factor_fluid    = displacement_factor_fluid + computeDisplacementFactorCell(dens, pm, neighbourPos, pos1, oldPos, originalIndex, cellStart, cellEnd, ir, kpg, rd, pm);
				displacement_factor_boundary = displacement_factor_boundary +computeDisplacementFactorBoundaryCell(dens, pm, neighbourPos, pos1, oldBoundaryPos, oldBoundaryVbi, cellBoundaryStart, cellBoundaryEnd, ir, kpg, rd, pm, dt);
			}
        }
    }

	/******************
	*  GLOBAL WRITE  *
	******************/
	oldDiiFluid[originalIndex]    = make_SVec4(displacement_factor_fluid.x, displacement_factor_fluid.y, displacement_factor_fluid.z, 0.0);
	oldDiiBoundary[originalIndex] = make_SVec4(displacement_factor_boundary.x, displacement_factor_boundary.y, displacement_factor_boundary.z, 0.0);
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal rho_adv_fluid(SReal ir, SReal pm, SUint index, SVec3 pos1, SVec3 velAdv1, SReal kpg, SVec4* oldPos, SVec4* oldVelAdv, int3 neighbourPos, SUint* cellStart, SUint* cellEnd)
{
	const SUint gridHash = calcGridHash(neighbourPos);
	const SUint startIndex = FETCH(cellStart, gridHash);

	SReal res  = 0.0;
	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);
		const SReal dt = sph_params.timestep;
        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				const SVec3 pos2    = make_SVec3(FETCH(oldPos, j));
				const SVec3 velAdv2 = make_SVec3(FETCH(oldVelAdv, j));
				const SVec3 v1v2    = velAdv1 - velAdv2;

				const SVec3 p1p2 = pos1 - pos2;

				if(length(p1p2) < ir)
				{
					SVec3 grad;
#if KERNEL_SET == MONAGHAN
					grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
					grad = Wdefault_grad(p1p2, ir, kpg);
#endif
					res += (dt*pm  * dot(v1v2, grad));
				}
			}
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal rho_adv_boundary(SVec3 pos1, SVec3 vel1, SReal rd, SReal pm, SReal ir, SReal kpg, int3 neighbourPos, SVec4* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd)
{
	const SUint gridHash = calcGridHash(neighbourPos);
	const SUint startIndex = FETCH(cellBoundaryStart, gridHash);
	SReal res = 0.0;

	if (startIndex != 0xffffffff)
	{
		const SUint endIndex = FETCH(cellBoundaryEnd, gridHash);
		const SReal dt = sph_params.timestep;
		for (SUint j=startIndex; j<endIndex; j++)
		{
			const SVec3 bpos = make_SVec3(FETCH(oldBoundaryPos, j));
			const SReal vbi = FETCH(oldBoundaryVbi, j);

			const SVec3 p1p2 = pos1 - bpos;
			const SVec3 v1v2 = vel1;
			const SReal psi  = (rd * vbi);

			SVec3 grad;
#if KERNEL_SET == MONAGHAN
			grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
			grad = Wdefault_grad(p1p2, ir, kpg);
#endif
			res += (dt*psi* dot(v1v2, grad));
		}
	}
	return res;
}
//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal compute_aii_cell(SReal ir, SReal dt, SReal pm, SReal kpg, SReal dens, SVec3 pos1, SVec3 diif, SVec3 diib, SVec4* oldPos, SUint* cellStart, SUint* cellEnd, int3 neighbourPos, SUint index)
{
	const SUint gridHash = calcGridHash(neighbourPos);
	const SUint startIndex = FETCH(cellStart, gridHash);

	SReal res  = 0.0;
	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);
        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
				const SVec3 p1p2 = pos1 - pos2;

				const SReal dpi = (pm)/(dens*dens);
				SVec3 grad;
#if KERNEL_SET == MONAGHAN
				grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
				grad = Wdefault_grad(p1p2, ir, kpg);
#endif
				SVec3 dji = dpi*grad;
				res += (pm * dot((diif+diib)-dji, grad));
			}
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__device__ SReal compute_aii_cell_boundary(SReal rd, SReal ir, SReal kpg, SReal dens, SVec3 diif, SVec3 diib, SVec3 pos1, SVec4* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd, int3 neighbourPos)
{
	const SUint gridHash = calcGridHash(neighbourPos);
	const SUint startIndex = FETCH(cellBoundaryStart, gridHash);
	SReal res = 0.0;

	const SReal pm = sph_params.particleMass;

	if (startIndex != 0xffffffff)
	{
		const SUint endIndex = FETCH(cellBoundaryEnd, gridHash);
		for (SUint j=startIndex; j<endIndex; j++)
		{
			const SVec3 pos2 = make_SVec3(FETCH(oldBoundaryPos, j));
			const SVec3 p1p2 = pos1 - pos2;
			const SReal vbi  = FETCH(oldBoundaryVbi, j);

			const SReal psi = rd*vbi;
			const SReal dpi = (pm)/(dens*dens);

			SVec3 grad;

#if KERNEL_SET == MONAGHAN
			grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
			grad = Wdefault_grad(p1p2, ir, kpg);
#endif

			const SVec3 dji = dpi * grad;

			res += psi * dot( (diif + diib) - dji, grad);
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  

__global__ void computeAdvectionFactor(
	SVec4        * oldPos,
	SVec4        * oldVel,
	SReal        * oldDens,
	SReal        * oldPres,
	SVec4        * oldForces,
	SVec4        * oldCol,
	SUint * cellStart,
	SUint * cellEnd,
	SUint * gridParticleIndex,
	SVec4        * oldBoundaryPos,
	SReal        * oldBoundaryVbi,
	SUint * cellBoundaryStart,
	SUint * cellBoundaryEnd,
	SUint * gridBoundaryIndex,
	SReal        * oldDensAdv,
	SReal        * oldDensCorr,
	SReal        * oldP_l,
	SReal        * oldPreviousP,
	SReal        * oldAii,
	SVec4        * oldVelAdv,
	SVec4        * oldForcesAdv,
	SVec4        * oldForcesP,
	SVec4        * oldDiiFluid,
	SVec4        * oldDiiBoundary,
	SVec4        * oldSumDij,
	SVec4        * oldNormal,
	SUint numParticles,
	SUint numBoundaries,
	SUint numCells)
{
    const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];

	//global memory reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 vel1 = make_SVec3(FETCH(oldVel, originalIndex));
	const SVec3 velAdv1 = make_SVec3(FETCH(oldVelAdv, originalIndex));
	const SReal dens = FETCH(oldDens, originalIndex);
	const SVec3 diif = make_SVec3(FETCH(oldDiiFluid, originalIndex));
	const SVec3 diib = make_SVec3(FETCH(oldDiiBoundary, originalIndex));

	//grid computation
    const int3 gridPos = calcGridPos(pos1);

	//const memory reads
	const SReal kpg= sph_params.kpoly_grad;
	const SReal pm = sph_params.particleMass;
	const SReal ir = sph_params.interactionRadius;
	const SReal rd = sph_params.restDensity;
	const SReal dt = sph_params.timestep;

	/*********************
	*  COMPUTE RHO_ADV  *
	*********************/
	SReal rho_advf= 0.0;
	SReal rho_advb= 0.0;

	//loop over fluid particles and boundary particles
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);

				rho_advf += rho_adv_fluid(ir, pm, originalIndex, pos1, velAdv1, kpg, oldPos, oldVelAdv, neighbourPos, cellStart, cellEnd);
				rho_advb += rho_adv_boundary(pos1, vel1, rd, pm, ir, kpg, neighbourPos, oldBoundaryPos, oldBoundaryVbi, cellBoundaryStart, cellBoundaryEnd);
			}
		}
	}

	/*******************
	*  WRITE RHO_ADV  *
	*******************/
	SReal rho_adv = dens + (rho_advf + rho_advb);
	oldDensAdv[originalIndex] = rho_adv; 

	/*******************
	*  COMPUTE P_i^0  *
	*******************/
	oldP_l[originalIndex] = 0.5 * oldPres[originalIndex]; 

	/*****************
	*  COMPUTE AII  *
	*****************/
	SReal aii = 0.0;
	const SReal dpi = pm / (dens*dens);
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);

				aii += compute_aii_cell(ir, dt, pm, kpg, dens, pos1, diif, diib, oldPos, cellStart, cellEnd, neighbourPos, originalIndex);
				aii += compute_aii_cell_boundary(rd, ir, kpg, dens, diif, diib, pos1, oldBoundaryPos, oldBoundaryVbi, cellBoundaryStart, cellBoundaryEnd, neighbourPos);
			}
		}
	}
	oldAii[originalIndex] = aii;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  

__device__ SVec3 dijpjcell(SReal ir, SReal pm, SReal kpg, SVec3 pos1, SVec4* oldPos, SReal* oldDens, SReal* oldP_l, SUint index, SUint *cellStart, SUint *cellEnd, int3 neighbourPos)
{
	SVec3 res = make_SVec3(0.0, 0.0, 0.0);
	const SUint gridHash = calcGridHash(neighbourPos);
	const SUint startIndex = FETCH(cellStart, gridHash);

	if (startIndex != 0xffffffff)
	{ 
		const SUint endIndex = FETCH(cellEnd, gridHash);
        for (SUint j=startIndex; j<endIndex; j++)
		{
			if(j != index)
			{
				//todo
				const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
				const SVec3 p1p2 = pos1 - pos2;
				const SReal p_lj = FETCH(oldP_l, j);
				const SReal densj = FETCH(oldDens, j);
				SVec3 grad;
#if KERNEL_SET == MONAGHAN
				grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
				grad = Wdefault_grad(p1p2, ir, kpg);
#endif
				res = res - ((pm/(densj*densj))*p_lj*grad);
			}
		}
	}
	return res;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  

__global__ void computeSumDijPj(
	SVec4        * oldPos,
	SVec4        * oldVel,
	SReal        * oldDens,
	SReal        * oldPres,
	SVec4        * oldForces,
	SVec4        * oldCol,
	SUint * cellStart,
	SUint * cellEnd,
	SUint * gridParticleIndex,
	SVec4        * oldBoundaryPos,
	SReal        * oldBoundaryVbi,
	SUint * cellBoundaryStart,
	SUint * cellBoundaryEnd,
	SUint * gridBoundaryIndex,
	SReal        * oldDensAdv,
	SReal        * oldDensCorr,
	SReal        * oldP_l,
	SReal        * oldPreviousP,
	SReal        * oldAii,
	SVec4        * oldVelAdv,
	SVec4        * oldForcesAdv,
	SVec4        * oldForcesP,
	SVec4        * oldDiiFluid,
	SVec4        * oldDiiBoundary,
	SVec4        * oldSumDij,
	SVec4        * oldNormal,
	SUint numParticles,
	SUint numBoundaries,
	SUint numCells
		)
{
    const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];

	//global reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));

	//grid compute
    const int3 gridPos = calcGridPos(pos1);

	//const reads
	const SReal ir = sph_params.interactionRadius;
	const SReal pm = sph_params.particleMass;
	const SReal kpg= sph_params.kpoly_grad;
	const SReal dt = sph_params.timestep;

	SVec3 dijpj = make_SVec3(0.0, 0.0, 0.0);
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);

				dijpj = dijpj + dijpjcell(ir, pm, kpg, pos1, oldPos, oldDens, oldP_l, originalIndex, cellStart, cellEnd, neighbourPos);
			}
		}
	}

	/******************
	*  GLOBAL WRITE  *
	******************/
	oldSumDij[originalIndex] = make_SVec4(dijpj.x, dijpj.y, dijpj.z, 0.0);
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void computePressure(
	SVec4        * oldPos,
	SVec4        * oldVel,
	SReal        * oldDens,
	SReal        * oldPres,
	SVec4        * oldForces,
	SVec4        * oldCol,
	SUint * cellStart,
	SUint * cellEnd,
	SUint * gridParticleIndex,
	SVec4        * oldBoundaryPos,
	SReal        * oldBoundaryVbi,
	SUint * cellBoundaryStart,
	SUint * cellBoundaryEnd,
	SUint * gridBoundaryIndex,
	SReal        * oldDensAdv,
	SReal        * oldDensCorr,
	SReal        * oldP_l,
	SReal        * oldPreviousP,
	SReal        * oldAii,
	SVec4        * oldVelAdv,
	SVec4        * oldForcesAdv,
	SVec4        * oldForcesP,
	SVec4        * oldDiiFluid,
	SVec4        * oldDiiBoundary,
	SVec4        * oldSumDij,
	SVec4        * oldNormal,
	SUint numParticles,
	SUint numBoundaries,
	SUint numCells
		)
{
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];

	//global reads
	const SVec3 pos1         = make_SVec3(FETCH(oldPos, originalIndex));
	const SReal dens         = FETCH(oldDens, originalIndex);
	SReal  p_l               = FETCH(oldP_l, originalIndex);
	const SReal previous_p_l = p_l;
	const SReal rho_adv      = FETCH(oldDensAdv, originalIndex);
	const SVec3 sum_dij      = make_SVec3(FETCH(oldSumDij, originalIndex));
	const SVec3 diif         = make_SVec3(FETCH(oldDiiFluid, originalIndex));
	const SVec3 diib         = make_SVec3(FETCH(oldDiiBoundary, originalIndex));
	const SReal aii          = FETCH(oldAii, originalIndex);
	const SVec3 dijpj        = make_SVec3(FETCH(oldSumDij, originalIndex));

	//grid compute
    const int3 gridPos = calcGridPos(pos1);

	//const reads
	const SReal ir = sph_params.interactionRadius;
	const SReal pm = sph_params.particleMass;
	const SReal kpg= sph_params.kpoly_grad;
	const SReal dt = sph_params.timestep;
	const SReal rd = sph_params.restDensity;

	SReal fsum = 0.0;
	SReal bsum = 0.0;

	const SReal dpi = pm / (dens*dens);
		
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				const SUint gridHash = calcGridHash(neighbourPos);
				const SUint startIndex = FETCH(cellStart, gridHash);

				if (startIndex != 0xffffffff)
				{ 
					const SUint endIndex = FETCH(cellEnd, gridHash);

					/***********
					*  FLUID  *
					***********/
					for (SUint j=startIndex; j<endIndex; j++)
					{
						if(j != index)
						{
							//todo
							const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
							const SVec3 p1p2 = pos1 - pos2;
							const SReal p_lj = FETCH(oldP_l, j);

							SVec3 grad;
#if KERNEL_SET == MONAGHAN
				grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
				grad = Wdefault_grad(p1p2, ir, kpg);
#endif

							const SVec3 dji = dpi*( grad );//FIXME nan issues
							const SVec3 d_ji_pi = dji * p_lj;

							const SVec3 diifj = make_SVec3(FETCH(oldDiiFluid, j));
							const SVec3 diibj = make_SVec3(FETCH(oldDiiBoundary, j));
							const SVec3 sum_dijj = make_SVec3(FETCH(oldSumDij, j));

							fsum += pm * dot( dijpj - (diifj+diibj)*p_lj - (sum_dijj - d_ji_pi), grad);
						}
					}
				}

				const SUint startIndexB = FETCH(cellBoundaryStart, gridHash);
				if (startIndexB != 0xffffffff) 
				{
					const SUint endIndexB = FETCH(cellBoundaryEnd, gridHash);

					
					/****************
					*  BOUNDARIES  *
					****************/
					for (SUint j=startIndex; j<endIndexB; j++)
					{
						const SVec3 posb = make_SVec3(FETCH(oldBoundaryPos, j));
						const SVec3 p1p2 = pos1 - posb;
						const SReal vbi = FETCH(oldBoundaryVbi, j);
						const SReal psi = rd * vbi;
						SVec3 grad;
#if KERNEL_SET == MONAGHAN
						grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
						grad = Wdefault_grad(p1p2, ir, kpg);
#endif
						bsum += psi * dot(dijpj, grad); 
					}
				}
			}
		}
	}

	SReal omega = 0.5;
	SReal rho_corr = rho_adv + fsum + bsum;
	const SReal dt2 = dt*dt;
	const SReal denom = aii * dt2;
	const SReal b = rd - rho_adv;

    if(fabs(denom)>FLT_EPSILON)
    {
        p_l = (1.0-omega)*previous_p_l + (omega/denom)*(b - dt2 * (bsum+fsum));
    }
    else
    {
        p_l = 0.0;
    }

	SReal p = fmax(p_l, 0.0);
	p_l = p;

	rho_corr += aii*previous_p_l;

	/******************
	*  GLOBAL WRITE  *
	******************/
	oldP_l[originalIndex]      = p_l;
	oldPres[originalIndex]     = p_l;
	oldDensCorr[originalIndex] = rho_corr;
}

//====================================================================================================  
//====================================================================================================  
//====================================================================================================  
__global__ void computePressureForce(
		SVec4        * oldPos,
		SVec4        * oldVel,
		SReal        * oldDens,
		SReal        * oldPres,
		SVec4        * oldForces,
		SVec4        * oldCol,
		SUint * cellStart,
		SUint * cellEnd,
		SUint * gridParticleIndex,
		SVec4        * oldBoundaryPos,
		SReal        * oldBoundaryVbi,
		SUint * cellBoundaryStart,
		SUint * cellBoundaryEnd,
		SUint * gridBoundaryIndex,
		SReal        * oldDensAdv,
		SReal        * oldDensCorr,
		SReal        * oldP_l,
		SReal        * oldPreviousP,
		SReal        * oldAii,
		SVec4        * oldVelAdv,
		SVec4        * oldForcesAdv,
		SVec4        * oldForcesP,
		SVec4        * oldDiiFluid,
		SVec4        * oldDiiBoundary,
		SVec4        * oldSumDij,
		SVec4        * oldNormal,
		SUint numParticles,
		SUint numBoundaries,
		SUint numCells
		)
{
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];

	//global reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 velAdv1 = make_SVec3(FETCH(oldVelAdv, originalIndex));
	const SReal p = FETCH(oldPres, originalIndex);
	const SReal dens = FETCH(oldDens, originalIndex);

	//grid compute
    const int3 gridPos = calcGridPos(pos1);

	//const reads
	const SReal ir = sph_params.interactionRadius;
	const SReal pm = sph_params.particleMass;
	const SReal kpg= sph_params.kpoly_grad;
	const SReal rd = sph_params.restDensity;
	
	/***************************
	*  UPDATE PRESSURE FORCE  *
	***************************/
	SVec3 fpres_res = make_SVec3(0.0, 0.0, 0.0);

	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				const SUint gridHash = calcGridHash(neighbourPos);
				const SUint startIndex = FETCH(cellStart, gridHash);

				if (startIndex != 0xffffffff)
				{ 
					const SUint endIndex = FETCH(cellEnd, gridHash);
					for (SUint j=startIndex; j<endIndex; j++)
					{
						if(j != index)
						{
							//todo
							const SVec3 pos2 = make_SVec3(FETCH(oldPos, j));
							const SVec3 p1p2 = pos1 - pos2;
							const SReal pj = FETCH(oldPres, j);
							const SReal densj = FETCH(oldDens, j);
							SVec3 grad;
#if KERNEL_SET == MONAGHAN
							grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
							grad = Wdefault_grad(p1p2, ir, kpg);
#endif
							const SVec3 contrib = -pm*pm*( p/(dens*dens) + pj/(densj*densj) ) * grad;

							fpres_res = fpres_res  + contrib;
						}
					}
				}

				const SUint startIndexB = FETCH(cellBoundaryStart, gridHash);
				if (startIndexB != 0xffffffff) 
				{
					const SUint endIndexB = FETCH(cellBoundaryEnd, gridHash);
					for (SUint j=startIndex; j<endIndexB; j++)
					{
						const SVec3 posb = make_SVec3(FETCH(oldBoundaryPos, j));
						const SVec3 p1p2 = pos1 - posb;
						const SReal vbi = FETCH(oldBoundaryVbi, j);
						const SReal psi = rd * vbi;

						SVec3 grad;
#if KERNEL_SET == MONAGHAN
						grad = Wmonaghan_grad(p1p2, ir);
#elif KERNEL_SET == MULLER
						grad = Wdefault_grad(p1p2, ir, kpg);
#endif

						const SVec3 contrib = (pm*psi*( p/(dens*dens) ) * grad);
						fpres_res = fpres_res + contrib;
					}
				}
			}
		}
	}

	/*if (length(fpres_res) <= 0.0) fpres_res = make_SVec3(0.0, 0.0, 0.0);*/

	/******************
	*  GLOBAL WRITE  *
	******************/
	oldForcesP[originalIndex] = make_SVec4(fpres_res.x, fpres_res.y, fpres_res.z, 0.0);
}

//==================================================================================================== 
//==================================================================================================== 
//==================================================================================================== 
__global__ void iisph_integrate(
			SVec4* oldPos,
			SVec4* oldVel,
			SVec4* oldVelAdv,
			SVec4* oldForcesP,
			SUint* gridParticleIndex,
			SUint numParticles
			)
{
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;

	const SUint originalIndex = gridParticleIndex[index];

	const SVec3 pos1    = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 velAdv1 = make_SVec3(FETCH(oldVelAdv, originalIndex));
	const SVec3 fpres1  = make_SVec3(FETCH(oldForcesP,originalIndex));

	const SReal dt = sph_params.timestep;
	const SReal pm = sph_params.particleMass;

	SVec3 newVel = velAdv1 + (dt*fpres1/pm);
	SVec3 newPos = pos1    + (dt*newVel);


	/******************
	 *  GLOBAL WRITE  *
	 ******************/
	oldPos[originalIndex] = make_SVec4(newPos.x, newPos.y, newPos.z, 1.0);
	oldVel[originalIndex] = make_SVec4(newVel.x, newVel.y, newVel.z, 0.0);
}

//==================================================================================================== 
//==================================================================================================== 
//==================================================================================================== 
/************
*  PCISPH  *
************/
__global__ void pciComputePosVelAdv(SVec4* oldPos, SVec4* oldVel, SReal* oldDens, SReal* oldPres, SVec4* oldForces, SVec4* oldCol, SUint* cellStart, SUint* cellEnd, SUint* gridParticleIndex,
				SVec4* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd, SUint* gridBoundaryIndex, SReal* oldRhoAdv, SVec4* oldVelAdvPci, 
				SVec4* oldForcesAdvPci, SVec4* oldForcesP, SVec4* oldNormal, SUint numParticles, SUint numBoundaries, SUint numCells)
{
	//particle index
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;
	const SUint originalIndex = gridParticleIndex[index];

	//global memory reads
	const SVec3 pos1 = make_SVec3(FETCH(oldPos, originalIndex));
	const SVec3 vel1 = make_SVec3(FETCH(oldVel, originalIndex));
	const SReal dens = FETCH(oldDens, originalIndex);

	//grid computation
    const int3 gridPos = calcGridPos(pos1);

	//const memory reads
	const SReal pm = sph_params.particleMass;
	const SReal dt = sph_params.timestep;

	/***********************
	*  PREDICT ADVECTION  *
	***********************/
	SVec3 fvisc = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fsurf = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fgrav = make_SVec3(0.0, 0.0, 0.0);
	SVec3 fbound= make_SVec3(0.0, 0.0, 0.0);
	SVec3 fpres = make_SVec3(0.0, 0.0, 0.0); //ignored here, just to reuse computeCellForces
	SReal pres  = 0.0;//same here

	//loop over neighbor cells
	for (int z=-1; z<=1; z++)
	{
		for (int y=-1; y<=1; y++)
		{
			for (int x=-1; x<=1; x++)
			{
				const int3 neighbourPos = gridPos + make_int3(x, y, z);
				computeCellForces(&fpres, &fvisc, &fsurf, &fbound, neighbourPos, originalIndex, pos1, vel1, dens, pres, oldPos, oldDens, oldPres, oldVel, gridBoundaryIndex, oldBoundaryPos, oldBoundaryVbi, cellStart, cellEnd, cellBoundaryStart, cellBoundaryEnd);
			}
		}
	}

	//end force computation
	fvisc = 2.0 * fvisc;
	fvisc = (pm*sph_params.viscosity) * fvisc;
	fgrav =  pm*sph_params.gravity;

	/*********************************************
	*  COMPUTE AND STORE FORCE_ADV and VEL_ADV  *
	*********************************************/
	SVec3 force_adv             = fvisc + fsurf + fbound + fgrav;
	SVec3 vel_adv               = vel1 + dt*(force_adv/pm);
	oldForcesAdvPci[originalIndex] = make_SVec4(force_adv.x, force_adv.y, force_adv.z, 0.0);
	oldVelAdvPci[originalIndex]    = make_SVec4(vel_adv.x, vel_adv.y, vel_adv.z, 0.0);

}

__global__ void pciPressureSolve(SReal* oldPos, SReal* oldVel, SReal* oldDens, SReal* oldPres, SReal* oldForces, SReal* oldCol, SUint* cellStart, SUint* cellEnd, SUint* gridParticleIndex,
				SReal* oldBoundaryPos, SReal* oldBoundaryVbi, SUint* cellBoundaryStart, SUint* cellBoundaryEnd, SUint* gridBoundaryIndex, SReal* oldRhoAdv, SReal* oldVelAdv, 
				SReal* oldForcesAdv, SReal* oldForcesP, SReal* oldNormal, SUint numParticles, SUint numBoundaries, SUint numCells)
{
	const SUint index = blockIdx.x*blockDim.x + threadIdx.x;
    if (index >= numParticles) return;

	const SUint originalIndex = gridParticleIndex[index];
}

#endif//_PARTICLES_KERNEL_IMPL_CUH

