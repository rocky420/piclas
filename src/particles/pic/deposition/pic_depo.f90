#include "boltzplatz.h"

MODULE  MOD_PICDepo                                                                                
!===================================================================================================================================
! MOD PIC Depo
!===================================================================================================================================
 IMPLICIT NONE                                                                                   
 PRIVATE                                                                                         
!===================================================================================================================================
 PUBLIC :: Deposition,InitializeDeposition, DepositionMPF                                        
!===================================================================================================================================
!===================================================================================================================================
INTERFACE Deposition
  MODULE PROCEDURE Deposition
END INTERFACE

INTERFACE InitializeDeposition
  MODULE PROCEDURE InitializeDeposition
END INTERFACE

INTERFACE DepositionMPF
  MODULE PROCEDURE DepositionMPF
END INTERFACE
!===================================================================================================================================

CONTAINS                                                                                           
                                                                                                   
SUBROUTINE InitializeDeposition
!===================================================================================================================================
! Initialize the deposition variables first
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_PICDepo_Vars!,  ONLY : DepositionType, source, r_sf, w_sf, r2_sf, r2_sf_inv
USE MOD_Particle_Vars ! crazy??
USE MOD_Globals_Vars,           ONLY:PI
USE MOD_Mesh_Vars,              ONLY:nElems, Elem_xGP
USE MOD_Interpolation_Vars,     ONLY:xGP
USE MOD_Basis,                  ONLY:BuildBernsteinVdm
USE MOD_PreProc,                ONLY:PP_N
USE MOD_ReadInTools,            ONLY:GETREAL,GETINT,GETLOGICAL,GETSTR,GETREALARRAY
USE MOD_PICInterpolation_Vars,  ONLY:InterpolationType
USE MOD_Eval_xyz,               ONLY:eval_xyz_elemcheck
!USE MOD_part_MPFtools, ONLY: GeoCoordToMap
! IMPLICIT VARIABLE HANDLING
 IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                   :: ALLOCSTAT, iElem, i, j, k, m, dir, weightrun, mm, r, s, t
REAL                      :: BetaFac, Temp(3), MappedGauss(1:PP_N+1), xmin, ymin, zmin, xmax, ymax, zmax
REAL                      :: auxiliary(0:3),weight(1:3,0:3)
!===================================================================================================================================

DepositionType = GETSTR('PIC-Deposition-Type','nearest_blurrycenter')
! check for interpolation type incompatibilities (cannot be done at interpolation_init
! because DepositionType is not known yet)
IF((TRIM(InterpolationType).EQ.'nearest_gausspoint').AND. &
   (TRIM(DepositionType).NE.'nearest_gausspoint')) THEN
  CALL abort(__STAMP__, &
    'ERROR in pic_depo.f90: Interpolation type nearest_gausspoint only allowed with same deposition type!')
END IF
!--- Allocate arrays for charge density collection and initialize
SDEALLOCATE(source)
ALLOCATE(source(1:4,0:PP_N,0:PP_N,0:PP_N,nElems),STAT=ALLOCSTAT)
IF (ALLOCSTAT.NE.0) THEN
  CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate source!')
END IF
SELECT CASE(TRIM(DepositionType))
CASE('nearest_blurrycenter')
CASE('nearest_blurycenter')
  DepositionType = 'nearest_blurrycenter'
CASE('nearest_gausspoint')
  ! Allocate array for particle positions in -1|1 space (used for deposition as well as interpolation)
  SDEALLOCATE(PartPosMapped)
  ALLOCATE(PartPosMapped(1:PDM%maxParticleNumber,1:3),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate mapped particle pos!')
  END IF
  ! compute the borders of the virtual volumes around the gauss points in -1|1 space
  ALLOCATE(GaussBorder(1:PP_N),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate Mapped Gauss Border Coords!')
  END IF
  DO i=0,PP_N
    ! bullshit here, use xGP
    !CALL Eval_XYZ_ElemCheck(Elem_xGP(:,i,1,1,1),Temp(:),1)
    !MappedGauss(i+1) = Temp(1)
    MappedGauss(i+1) = xGP(i)
  END DO
  DO i = 1,PP_N
    GaussBorder(i) = (MappedGauss(i+1) + MappedGauss(i))/2
  END DO
  ! allocate array for saving the gauss points of particles for nearest_gausspoint interpolation
  IF(TRIM(InterpolationType).EQ.'nearest_gausspoint')THEN
    SDEALLOCATE(PartPosGauss)
    ALLOCATE(PartPosGauss(1:PDM%maxParticleNumber,1:3),STAT=ALLOCSTAT)
    IF (ALLOCSTAT.NE.0) THEN
      CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate Part Pos Gauss!')
    END IF
  END IF
CASE('shape_function')
  r_sf     = GETREAL('PIC-shapefunction-radius','1.')
  alpha_sf = GETINT('PIC-shapefunction-alpha','2')
  BetaFac = beta(1.5, REAL(alpha_sf) + 1.)
  w_sf = 1./(2. * BetaFac * REAL(alpha_sf) + 2 * BetaFac) &
                        * (REAL(alpha_sf) + 1.)/(PI*(r_sf**3))
  r2_sf = r_sf * r_sf 
  r2_sf_inv = 1./r2_sf
  CALL abort(__STAMP__,&
      ' Shape function parallelization unter production. ')
CASE('delta_distri')
  ! Allocate array for particle positions in -1|1 space (used for deposition as well as interpolation)
  ALLOCATE(PartPosMapped(1:PDM%maxParticleNumber,1:3),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate mapped particle pos!')
  END IF
  UseBernStein = GETLOGICAL('PIC-DeltaBernStein','.FALSE.')
  IF(UseBernStein) CALL BuildBernSteinVdm(PP_N,xGP)
CASE('cartmesh_volumeweighting')

  CALL abort(__STAMP__,&
      ' cartmesh parallelization unter production. ')
  ! read in background mesh size
  BGMdeltas(1:3) = GETREALARRAY('PIC-BGMdeltas',3,'0. , 0. , 0.')
  FactorBGM(1:3) = GETREALARRAY('PIC-FactorBGM',3,'1. , 1. , 1.')
  BGMdeltas(1:3) = 1./FactorBGM(1:3)*BGMdeltas(1:3)
  IF (ANY(BGMdeltas.EQ.0.0)) THEN
    CALL abort(__STAMP__, &
      'ERROR: PIC-BGMdeltas: No size for the cartesian background mesh definded.')
  END IF
  ! calc min and max coordinates for local mesh
  xmin = 1.0E200
  ymin = 1.0E200
  zmin = 1.0E200
  xmax = -1.0E200
  ymax = -1.0E200
  zmax = -1.0E200
  DO iElem = 1, nElems
    DO i = 1,8
      xmin = MIN(xmin,GEO%NodeCoords(1,GEO%ElemToNodeID(i,iElem)))
      ymin = MIN(ymin,GEO%NodeCoords(2,GEO%ElemToNodeID(i,iElem)))
      zmin = MIN(zmin,GEO%NodeCoords(3,GEO%ElemToNodeID(i,iElem)))
      xmax = MAX(xmax,GEO%NodeCoords(1,GEO%ElemToNodeID(i,iElem)))
      ymax = MAX(ymax,GEO%NodeCoords(2,GEO%ElemToNodeID(i,iElem)))
      zmax = MAX(zmax,GEO%NodeCoords(3,GEO%ElemToNodeID(i,iElem)))
    END DO
  END DO
  ! define minimum and maximum backgroundmesh index, compute volume
  BGMVolume = BGMdeltas(1)*BGMdeltas(2)*BGMdeltas(3)
  BGMminX = FLOOR(xmin/BGMdeltas(1)-0.0001)
  BGMminY = FLOOR(ymin/BGMdeltas(2)-0.0001)
  BGMminZ = FLOOR(zmin/BGMdeltas(3)-0.0001)
  BGMmaxX = CEILING(xmax/BGMdeltas(1)+0.0001)
  BGMmaxY = CEILING(ymax/BGMdeltas(2)+0.0001)
  BGMmaxZ = CEILING(zmax/BGMdeltas(3)+0.0001)
  ! mapping from gausspoints to BGM
  ALLOCATE(GaussBGMIndex(1:3,0:PP_N,0:PP_N,0:PP_N,1:nElems),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate GaussBGMIndex!') 
  END IF
  ALLOCATE(GaussBGMFactor(1:3,0:PP_N,0:PP_N,0:PP_N,1:nElems),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate GaussBGMFactor!')
  END IF
  DO iElem = 1, nElems
    DO j = 0, PP_N
      DO k = 0, PP_N
        DO m = 0, PP_N
          GaussBGMIndex(1,j,k,m,iElem) = FLOOR(Elem_xGP(1,j,k,m,iElem)/BGMdeltas(1))
          GaussBGMIndex(2,j,k,m,iElem) = FLOOR(Elem_xGP(2,j,k,m,iElem)/BGMdeltas(2))
          GaussBGMIndex(3,j,k,m,iElem) = FLOOR(Elem_xGP(3,j,k,m,iElem)/BGMdeltas(3))
          GaussBGMFactor(1,j,k,m,iElem) = (Elem_xGP(1,j,k,m,iElem)/BGMdeltas(1))-REAL(GaussBGMIndex(1,j,k,m,iElem))
          GaussBGMFactor(2,j,k,m,iElem) = (Elem_xGP(2,j,k,m,iElem)/BGMdeltas(2))-REAL(GaussBGMIndex(2,j,k,m,iElem))
          GaussBGMFactor(3,j,k,m,iElem) = (Elem_xGP(3,j,k,m,iElem)/BGMdeltas(3))-REAL(GaussBGMIndex(3,j,k,m,iElem))
        END DO
      END DO
    END DO
  END DO
#ifdef MPI
  CALL MPIBackgroundMeshInit()
#else
  IF(GEO%nPeriodicVectors.GT.0)THEN
    ! Compute PeriodicBGMVectors (from PeriodicVectors and BGMdeltas)
    ALLOCATE(GEO%PeriodicBGMVectors(1:3,1:GEO%nPeriodicVectors),STAT=allocStat)
    IF (allocStat .NE. 0) THEN
      CALL abort(__STAMP__, &
      'ERROR in MPIBackgroundMeshInit: cannot allocate GEO%PeriodicBGMVectors!')
    END IF
    DO i = 1, GEO%nPeriodicVectors
      GEO%PeriodicBGMVectors(1,i) = NINT(GEO%PeriodicVectors(1,i)/BGMdeltas(1))
      IF(ABS(GEO%PeriodicVectors(1,i)/BGMdeltas(1)-REAL(GEO%PeriodicBGMVectors(1,i))).GT.1E-10)THEN
        CALL abort(__STAMP__, &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
      GEO%PeriodicBGMVectors(2,i) = NINT(GEO%PeriodicVectors(2,i)/BGMdeltas(2))
      IF(ABS(GEO%PeriodicVectors(2,i)/BGMdeltas(2)-REAL(GEO%PeriodicBGMVectors(2,i))).GT.1E-10)THEN
        CALL abort(__STAMP__, &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
      GEO%PeriodicBGMVectors(3,i) = NINT(GEO%PeriodicVectors(3,i)/BGMdeltas(3))
      IF(ABS(GEO%PeriodicVectors(3,i)/BGMdeltas(3)-REAL(GEO%PeriodicBGMVectors(3,i))).GT.1E-10)THEN
        CALL abort(__STAMP__, &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
    END DO
  END IF
#endif
CASE('cartmesh_splines')
  CALL abort(__STAMP__,&
      ' cartmesh parallelization unter production. ')
  BGMdeltas(1:3) = GETREALARRAY('PIC-BGMdeltas',3,'0. , 0. , 0.')
  FactorBGM(1:3) = GETREALARRAY('PIC-FactorBGM',3,'1. , 1. , 1.')
  BGMdeltas(1:3) = 1./FactorBGM(1:3)*BGMdeltas(1:3)
  IF (ANY(BGMdeltas.EQ.0)) THEN
    CALL abort(__STAMP__, &
      'ERROR: PIC-BGMdeltas: No size for the cartesian background mesh definded.')
  END IF
  ! calc min and max coordinates for local mesh
  xmin = 1.0E200
  ymin = 1.0E200
  zmin = 1.0E200
  xmax = -1.0E200
  ymax = -1.0E200
  zmax = -1.0E200
  DO iElem = 1, nElems
    DO i = 1,8
      xmin = MIN(xmin,GEO%NodeCoords(1,GEO%ElemToNodeID(i,iElem)))
      ymin = MIN(ymin,GEO%NodeCoords(2,GEO%ElemToNodeID(i,iElem)))
      zmin = MIN(zmin,GEO%NodeCoords(3,GEO%ElemToNodeID(i,iElem)))
      xmax = MAX(xmax,GEO%NodeCoords(1,GEO%ElemToNodeID(i,iElem)))
      ymax = MAX(ymax,GEO%NodeCoords(2,GEO%ElemToNodeID(i,iElem)))
      zmax = MAX(zmax,GEO%NodeCoords(3,GEO%ElemToNodeID(i,iElem)))
    END DO
  END DO
  ! define minimum and maximum backgroundmesh index, compute volume
  BGMVolume = BGMdeltas(1)*BGMdeltas(2)*BGMdeltas(3)
  BGMminX = FLOOR(xmin/BGMdeltas(1)-0.0001)-2
  BGMminY = FLOOR(ymin/BGMdeltas(2)-0.0001)-2
  BGMminZ = FLOOR(zmin/BGMdeltas(3)-0.0001)-2
  BGMmaxX = CEILING(xmax/BGMdeltas(1)+0.0001)+2
  BGMmaxY = CEILING(ymax/BGMdeltas(2)+0.0001)+2
  BGMmaxZ = CEILING(zmax/BGMdeltas(3)+0.0001)+2
  ! mapping from gausspoints to BGM
  ALLOCATE(GaussBGMIndex(1:3,0:PP_N,0:PP_N,0:PP_N,1:nElems),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate GaussBGMIndex!')
  END IF
  ALLOCATE(GaussBGMFactor(1:3,0:PP_N,0:PP_N,0:PP_N,1:nElems),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate GaussBGMFactor!')
  END IF
  DO iElem = 1, nElems
    DO j = 0, PP_N
      DO k = 0, PP_N
        DO m = 0, PP_N
          GaussBGMIndex(1,j,k,m,iElem) = FLOOR(Elem_xGP(1,j,k,m,iElem)/BGMdeltas(1))
          GaussBGMIndex(2,j,k,m,iElem) = FLOOR(Elem_xGP(2,j,k,m,iElem)/BGMdeltas(2))
          GaussBGMIndex(3,j,k,m,iElem) = FLOOR(Elem_xGP(3,j,k,m,iElem)/BGMdeltas(3))
        END DO
      END DO
    END DO
  END DO
  ! pre-build weights for BGM to gausspoint interpolation
  ALLOCATE(GPWeight(1:nElems,0:PP_N,0:PP_N,0:PP_N,1:4,1:4,1:4),STAT=ALLOCSTAT)
  IF (ALLOCSTAT.NE.0) THEN
    CALL abort(__STAMP__, &
      'ERROR in pic_depo.f90: Cannot allocate GPWeight!')
  END IF
  DO iElem = 1, nElems
    DO j = 0, PP_N
      DO k = 0, PP_N
        DO m = 0, PP_N
          DO dir = 1,3               ! x,y,z direction
            DO weightrun = 0,3
              DO mm = 0, 3
                IF (mm.EQ.weightrun) then
                  auxiliary(mm) = 1.0
                ELSE
                  auxiliary(mm) = 0.0
                END IF
              END DO
              CALL DeBoor(GaussBGMIndex(dir,j,k,m,iElem),auxiliary,Elem_xGP(dir,j,k,m,iElem),weight(dir,weightrun),dir)
            END DO
          END DO
          DO r = 1,4
            DO s = 1,4
              DO t = 1,4
                GPWeight(iElem,j,k,m,r,s,t) = weight(1,-(r-4)) * weight(2,-(s-4)) * weight(3,-(t-4))
              END DO !t
            END DO !s
          END DO !r
        END DO !m
      END DO !k
    END DO !j
  END DO !iElem
#ifdef MPI
  CALL MPIBackgroundMeshInit()
#else
  IF(GEO%nPeriodicVectors.GT.0)THEN
    ! Compute PeriodicBGMVectors (from PeriodicVectors and BGMdeltas)
    ALLOCATE(GEO%PeriodicBGMVectors(1:3,1:GEO%nPeriodicVectors),STAT=allocStat)
    IF (allocStat .NE. 0) THEN
      CALL abort(__STAMP__, &
      'ERROR in MPIBackgroundMeshInit: cannot allocate GEO%PeriodicBGMVectors!')
    END IF
    DO i = 1, GEO%nPeriodicVectors
      GEO%PeriodicBGMVectors(1,i) = NINT(GEO%PeriodicVectors(1,i)/BGMdeltas(1))
      IF(ABS(GEO%PeriodicVectors(1,i)/BGMdeltas(1)-REAL(GEO%PeriodicBGMVectors(1,i))).GT.1E-10)THEN
        CALL abort(__STAMP__,  &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
      GEO%PeriodicBGMVectors(2,i) = NINT(GEO%PeriodicVectors(2,i)/BGMdeltas(2))
      IF(ABS(GEO%PeriodicVectors(2,i)/BGMdeltas(2)-REAL(GEO%PeriodicBGMVectors(2,i))).GT.1E-10)THEN
        CALL abort(__STAMP__, &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
      GEO%PeriodicBGMVectors(3,i) = NINT(GEO%PeriodicVectors(3,i)/BGMdeltas(3))
      IF(ABS(GEO%PeriodicVectors(3,i)/BGMdeltas(3)-REAL(GEO%PeriodicBGMVectors(3,i))).GT.1E-10)THEN
        CALL abort(__STAMP__, &
      'ERROR: Periodic Vector ist not multiple of background mesh delta')
      END IF
    END DO
  END IF
#endif
CASE DEFAULT
  CALL abort(__STAMP__, &
      'Unknown DepositionType in pic_depo.f90')
END SELECT
END SUBROUTINE InitializeDeposition

SUBROUTINE Deposition(doInnerParts)  
!============================================================================================================================
! This subroutine performes the deposition of the particle charge and current density to the grid
! following list of distribution methods are implemted
! - nearest blurrycenter (barycenter of hexahedra)
! - nearest Gauss Point  (only volome of IP - higher resolution than nearest blurrycenter )
! - shape function       (only one type implemented)
! - delta distributio
!============================================================================================================================
! use MODULES
USE MOD_PICDepo_Vars
USE MOD_Particle_Vars
USE MOD_PreProc
USE MOD_Mesh_Vars,             ONLY:nElems, Elem_xGP, sJ
USE MOD_Globals
!USE MOD_part_MPI_Vars,         ONLY:casematrix, NbrOfCases
USE MOD_Interpolation_Vars,    ONLY:wGP,swGP,NChooseK
USE MOD_PICInterpolation_Vars, ONLY:InterpolationType
USE MOD_Eval_xyz,              ONLY:eval_xyz_elemcheck
USE MOD_Basis,                 ONLY:LagrangeInterpolationPolys,BernSteinPolynomial
USE MOD_Interpolation_Vars,    ONLY:wBary,xGP
#ifdef MPI
! only required for shape function??
USE MOD_part_MPI_Vars, ONLY : ExtPartState, ExtPartSpecies, NbrOfextParticles
USE MOD_Particle_MPI_Vars,    ONLY:PartMPI,PartMPIExchange
#endif 
!-----------------------------------------------------------------------------------------------------------------------------------
! IMPLICIT VARIABLE HANDLING
  IMPLICIT NONE                                                                                   
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT variable declaration                                                                       
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT variable declaration                                                                       
!-----------------------------------------------------------------------------------------------------------------------------------
! Local variable declaration                                                                       
!-----------------------------------------------------------------------------------------------------------------------------------
LOGICAL                          :: doInnerParts
INTEGER                          :: firstPart,lastPart
INTEGER                          :: i,j, k, l, m, Element, iElem, iPart
LOGICAL                          :: chargedone(1:nElems), SAVE_GAUSS             
INTEGER                          :: kmin, kmax, lmin, lmax, mmin, mmax                           
INTEGER                          :: kk, ll, mm, ppp                                              
INTEGER                          :: ElemID, iCase, ind
REAL                             :: radius, S, S1, Fac(4)
REAL                             :: Vec1(1:3), Vec2(1:3), Vec3(1:3), ShiftedPart(1:3)
INTEGER                          :: a,b, ii, expo
REAL                             :: ElemSource(nElems,1:4)
REAL, ALLOCATABLE                :: BGMSource(:,:,:,:)
REAL                             :: Charge, TSource(1:4), auxiliary(0:3),weight(1:3,0:3), locweight
REAL                             :: alpha1, alpha2, alpha3
INTEGER                          :: PosInd(3),r,ss,t,u,v,w, dir, weightrun
REAL,DIMENSION(3,0:PP_N)         :: L_xi
REAL                             :: DeltaIntCoeff,prefac
!============================================================================================================================

IF(doInnerParts)THEN
  source=0.0
  firstPart=1
  lastPart=PDM%ParticleVecLength
ELSE
#ifdef MPI
  firstPart=PDM%ParticleVecLength-PartMPIExchange%nMPIParticles+1
  lastPart=PDM%ParticleVecLength
#endif /*MPI*/
END IF
IF(firstPart.GT.lastPart) RETURN

SELECT CASE(TRIM(DepositionType))
CASE('nearest_blurrycenter')
  ElemSource=0.0
  DO i=firstPart,lastPart
    IF (PDM%ParticleInside(i)) THEN
      Element = PEM%Element(i)
#if (PP_nVar==8)
      ElemSource(Element,1:3) = ElemSource(Element,1:3)+ &
             PartState(i,4:6)* Species(PartSpecies(i))%ChargeIC * Species(PartSpecies(i))%MacroParticleFactor
#endif
      ElemSource(Element,4) = ElemSource(Element,4) + & 
           Species(PartSpecies(i))%ChargeIC* Species(PartSpecies(i))%MacroParticleFactor
    END IF
  END DO
  DO Element=1,nElems
#if (PP_nVar==8)
    source(1,:,:,:,Element) = ElemSource(Element,1)
    source(2,:,:,:,Element) = ElemSource(Element,2)
    source(3,:,:,:,Element) = ElemSource(Element,3)
#endif
    source(4,:,:,:,Element) = ElemSource(Element,4)
  END DO
  DO Element=1,nElems
#if (PP_nVar==8)
    source(1:4,:,:,:,Element) = source(1:4,:,:,:,Element) / GEO%Volume(Element)
#else
    source(4,:,:,:,Element) = source(4,:,:,:,Element) / GEO%Volume(Element)
#endif
  END DO
CASE('shape_function')
!   Vec1(1:3) = 0.
!   Vec2(1:3) = 0.
!   Vec3(1:3) = 0.
!   IF (GEO%nPeriodicVectors.EQ.1) THEN
!     Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!   END IF
!   IF (GEO%nPeriodicVectors.EQ.2) THEN
!     Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!     Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
!   END IF
!   IF (GEO%nPeriodicVectors.EQ.3) THEN
!     Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!     Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
!     Vec3(1:3) = GEO%PeriodicVectors(1:3,3)
!   END IF
!   DO i=firstPart,lastPart
!     IF (PDM%ParticleInside(i)) THEN
!       Fac(4) = Species(PartSpecies(i))%ChargeIC * Species(PartSpecies(i))%MacroParticleFactor*w_sf
!       Fac(1:3) = PartState(i,4:6)*Fac(4)
!       !-- determine which background mesh cells (and interpolation points within) need to be considered
!       DO iCase = 1, NbrOfCases
!         chargedone(:) = .FALSE.
!         DO ind = 1,3
!           ShiftedPart(ind) = PartState(i,ind) + casematrix(iCase,1)*Vec1(ind) + &
!                casematrix(iCase,2)*Vec2(ind) + casematrix(iCase,3)*Vec3(ind)
!         END DO
!         kmax = CEILING((ShiftedPart(1)+r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1))
!         kmax = MIN(kmax,GEO%FIBGMimax)
!         kmin = FLOOR((ShiftedPart(1)-r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1)+1)
!         kmin = MAX(kmin,GEO%FIBGMimin)
!         lmax = CEILING((ShiftedPart(2)+r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2))
!         lmax = MIN(lmax,GEO%FIBGMkmax)
!         lmin = FLOOR((ShiftedPart(2)-r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2)+1)
!         lmin = MAX(lmin,GEO%FIBGMkmin)
!         mmax = CEILING((ShiftedPart(3)+r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3))
!         mmax = MIN(mmax,GEO%FIBGMlmax)
!         mmin = FLOOR((ShiftedPart(3)-r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3)+1)
!         mmin = MAX(mmin,GEO%FIBGMlmin)
!         !-- go through all these cells
!         DO kk = kmin,kmax
!           DO ll = lmin, lmax
!             DO mm = mmin, mmax
!               !--- go through all mapped elements not done yet
!               DO ppp = 1,GEO%FIBGM(kk,ll,mm)%nElem
!                 ElemID = GEO%FIBGM(kk,ll,mm)%Element(ppp)
!                 IF (.NOT.chargedone(ElemID)) THEN
!                   !--- go through all gauss points
!                   DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
!                     !-- calculate distance between gauss and particle
!                     radius = (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) * (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) &
!                            + (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) * (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) &
!                            + (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID)) * (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID))
!                     !-- calculate charge and current density at ip point using a shape function
!                     !-- currently only one shapefunction available, more to follow (including structure change)
!                     IF (radius .LT. r2_sf) THEN
!                       S = 1 - r2_sf_inv * radius
!                       S1 = S*S
!                       DO expo = 3, alpha_sf
!                         S1 = S*S1
!                       END DO
! #if (PP_nVar==8)
!                       source(1:3,k,l,m,ElemID) = source(1:3,k,l,m,ElemID) + Fac(1:3) * S1
! #endif
!                       source( 4 ,k,l,m,ElemID) = source( 4 ,k,l,m,ElemID) + Fac(4) * S1
!                     END IF
!                   END DO; END DO; END DO
!                   chargedone(ElemID) = .TRUE.
!                 END IF
!               END DO ! ppp
!             END DO ! mm
!           END DO ! ll
!         END DO ! kk
!       END DO ! iCase (periodicity)
!     END IF ! inside
!   END DO ! i
! 
! #ifdef MPI           
!   Vec1(1:3) = 0.
!   Vec2(1:3) = 0.
!   Vec3(1:3) = 0.
!   IF (NbrOfextParticles .GT. 0) THEN
!     IF (GEO%nPeriodicVectors.EQ.1) THEN
!       Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!     END IF
!     IF (GEO%nPeriodicVectors.EQ.2) THEN
!       Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!       Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
!     END IF
!     IF (GEO%nPeriodicVectors.EQ.3) THEN
!       Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
!       Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
!       Vec3(1:3) = GEO%PeriodicVectors(1:3,3)
!     END IF
!   END IF
!   
!   DO iPart=1,NbrOfextParticles  !external Particles
!     chargedone(:) = .FALSE.
!     Fac(4) = Species(ExtPartSpecies(iPart))%ChargeIC * Species(ExtPartSpecies(iPart))%MacroParticleFactor*w_sf
!     Fac(1:3) = ExtPartState(iPart,4:6)*Fac(4)
!     !-- determine which background mesh cells (and interpolation points within) need to be considered
!     DO iCase = 1, NbrOfCases
!       DO ind = 1,3
!         ShiftedPart(ind) = ExtPartState(iPart,ind) + casematrix(iCase,1)*Vec1(ind) + &
!              casematrix(iCase,2)*Vec2(ind) + casematrix(iCase,3)*Vec3(ind)
!       END DO
!       kmax = CEILING((ShiftedPart(1)+r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1))
!       kmax = MIN(kmax,GEO%FIBGMimax)
!       kmin = FLOOR((ShiftedPart(1)-r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1)+1)
!       kmin = MAX(kmin,GEO%FIBGMimin)
!       lmax = CEILING((ShiftedPart(2)+r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2))
!       lmax = MIN(lmax,GEO%FIBGMkmax)
!       lmin = FLOOR((ShiftedPart(2)-r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2)+1)
!       lmin = MAX(lmin,GEO%FIBGMkmin)
!       mmax = CEILING((ShiftedPart(3)+r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3))
!       mmax = MIN(mmax,GEO%FIBGMlmax)
!       mmin = FLOOR((ShiftedPart(3)-r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3)+1)
!       mmin = MAX(mmin,GEO%FIBGMlmin)
!       !-- go through all these cells (should go through non if periodic and shiftedpart not in my domain
!       DO kk = kmin,kmax
!         DO ll = lmin, lmax
!           DO mm = mmin, mmax
!             !--- go through all mapped elements not done yet
!             DO ppp = 1,GEO%FIBGM(kk,ll,mm)%nElem
!               ElemID = GEO%FIBGM(kk,ll,mm)%Element(ppp)
!               IF (.NOT.chargedone(ElemID)) THEN
!                 !--- go through all gauss points
!                 DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
!                   !-- calculate distance between gauss and particle
!                     radius = (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) * (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) &
!                            + (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) * (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) &
!                            + (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID)) * (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID))
!                     !-- calculate charge and current density at ip point using a shape function
!                     !-- currently only one shapefunction available, more to follow (including structure change)
!                     IF (radius .LT. r2_sf) THEN
!                       S = 1 - r2_sf_inv * radius
!                       S1 = S*S
!                       DO expo = 3, alpha_sf
!                         S1 = S*S1
!                       END DO
! #if (PP_nVar==8)
!                       source(1:3,k,l,m,ElemID) = source(1:3,k,l,m,ElemID) + Fac(1:3) * S1
! #endif
!                       source( 4 ,k,l,m,ElemID) = source( 4 ,k,l,m,ElemID) + Fac(4) * S1
!                     END IF
!                 END DO; END DO; END DO
!                 chargedone(ElemID) = .TRUE.
!               END IF
!             END DO ! ppp
!           END DO ! mm
!         END DO ! ll
!       END DO ! kk
!     END DO
!   END DO
!   SDEALLOCATE(ExtPartState)
!   SDEALLOCATE(ExtPartSpecies)
! #endif
CASE('delta_distri')
    DO iElem=1,PP_nElems
      DO iPart=firstPart,lastPart
        IF (PDM%ParticleInside(iPart)) THEN
          IF(PEM%Element(iPart).EQ.iElem)THEN
            prefac= Species(PartSpecies(iPart))%ChargeIC * Species(PartSpecies(iPart))%MacroParticleFactor 
            ! Map Particle to -1|1 space (re-used in interpolation)
            CALL Eval_xyz_ElemCheck(PartState(iPart,1:3),PartPosMapped(iPart,1:3),iElem)
            ! get value of test function at particle position
            IF(UseBernStein)THEN
              !print*,'here'
              DO i=0,PP_N
                ! xi   -direction
                 CALL BernsteinPolynomial(PP_N,i,PartPosMapped(iPart,1),L_xi(1,i),NChooseK)
                ! eta  -direction
                 CALL BernsteinPolynomial(PP_N,i,PartPosMapped(iPart,2),L_xi(2,i),NChooseK)
                ! zeta  -direction
                 CALL BernsteinPolynomial(PP_N,i,PartPosMapped(iPart,3),L_xi(3,i),NChooseK)
              END DO ! i
            ELSE
              !print*,'not here'
              ! xi   -direction
              CALL LagrangeInterpolationPolys(PartPosMapped(iPart,1),PP_N,xGP,wBary,L_xi(1,:))
              ! eta  -direction
              CALL LagrangeInterpolationPolys(PartPosMapped(iPart,2),PP_N,xGP,wBary,L_xi(2,:))
              ! zeta -direction
              CALL LagrangeInterpolationPolys(PartPosMapped(iPart,3),PP_N,xGP,wBary,L_xi(3,:))
            END IF
            DO k=0,PP_N
              DO j=0,PP_N
                DO i=0,PP_N
             !     print*,'i,j,k,L',i,j,k,L_xi(1,i)* L_xi(2,j)* L_xi(3,k)
                  DeltaIntCoeff = L_xi(1,i)* L_xi(2,j)* L_xi(3,k)*prefac 
#if (PP_nVar==8)
                  source(1:3,i,j,k,iElem) = source(1:3,i,j,k,iElem) + DeltaIntCoeff*PartState(iPart,4:6)
#endif
                  source( 4 ,i,j,k,iElem) = source( 4 ,i,j,k,iElem) + DeltaIntCoeff
                END DO ! i
              END DO ! j
            END DO ! k
          END IF ! Particle in Element
        END IF ! ParticleInside of domain
      END DO ! ParticleVecLength
      ! now, mapp from reference element into physical space
      !IF(UseBernStein)THEN
      !  !CALL ChangeBasis3D(4,PP_N,PP_N,Vdm_BernSteinN_GaussN,source(:,:,:,:,iElem),source(:,:,:,:,iElem))
      !  !CALL ChangeBasis3D(4,PP_N,PP_N,sVdm_BernSteinN_GaussN,source(:,:,:,:,iElem),source(:,:,:,:,iElem))
      !END IF
      DO k=0,PP_N
        DO j=0,PP_N
          DO i=0,PP_N
#if (PP_nVar==8)
            source( : ,i,j,k,iElem) = source( : ,i,j,k,iElem) *sJ(i,j,k,iElem)*swGP(i)*swGP(j)*swGP(k)
#else
            source( 4 ,i,j,k,iElem) = source( 4 ,i,j,k,iElem) *sJ(i,j,k,iElem)*swGP(i)*swGP(j)*swGP(k)
#endif
          END DO ! i
        END DO ! j
      END DO ! k
    END DO ! loop over all elems

CASE('nearest_gausspoint')
  SAVE_GAUSS = .FALSE.
  IF(TRIM(InterpolationType).EQ.'nearest_gausspoint') SAVE_GAUSS = .TRUE.
  IF(MOD(PP_N,2).EQ.0) THEN
    a = PP_N/2
    b = a
  ELSE
    a = (PP_N+1)/2
    b = a-1
  END IF
  DO i=firstPart,lastPart
    IF (PDM%ParticleInside(i)) THEN
      Element = PEM%Element(i)
      ! Map Particle to -1|1 space (re-used in interpolation)
      CALL Eval_XYZ_ElemCheck(PartState(i,1:3),PartPosMapped(i,1:3),Element)
      ! Find out which gausspoint is closest and add up charges and currents
      !! x-direction
      k = a
      DO ii = 0,b-1
        IF(ABS(PartPosMapped(i,1)).GE.GaussBorder(PP_N-ii))THEN
          k = PP_N-ii
          EXIT
        END IF
      END DO
      k = NINT((PP_N+SIGN(2.0*k-PP_N,PartPosMapped(i,1)))/2)
      !! y-direction
      l = a
      DO ii = 0,b-1
        IF(ABS(PartPosMapped(i,2)).GE.GaussBorder(PP_N-ii))THEN
          l = PP_N-ii
          EXIT
        END IF
      END DO
      l = NINT((PP_N+SIGN(2.0*l-PP_N,PartPosMapped(i,2)))/2)
      !! z-direction
      m = a
      DO ii = 0,b-1
        IF(ABS(PartPosMapped(i,3)).GE.GaussBorder(PP_N-ii))THEN
          m = PP_N-ii
          EXIT
        END IF
      END DO
      m = NINT((PP_N+SIGN(2.0*m-PP_N,PartPosMapped(i,3)))/2)
#if (PP_nVar==8)
      source(1:3,k,l,m,Element) = source(1:3,k,l,m,Element) + PartState(i,4:6) & !* Species(PartSpecies(i))%ChargeIC
                                      * Species(PartSpecies(i))%ChargeIC &
                                      * Species(PartSpecies(i))%MacroParticleFactor
#endif
      source( 4 ,k,l,m,Element) = source( 4 ,k,l,m,Element) & !Species(PartSpecies(i))%ChargeIC
                                      + Species(PartSpecies(i))%ChargeIC &
                                      * Species(PartSpecies(i))%MacroParticleFactor
      IF (SAVE_GAUSS) THEN
        PartPosGauss(i,1) = k
        PartPosGauss(i,2) = l
        PartPosGauss(i,3) = m
      END IF
    END IF
  END DO
  DO Element=1,nElems
    DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
      !get densities by dividing by pseudo gauss volume
#if (PP_nVar==8)
      source(1:4,k,l,m,Element) = source(1:4,k,l,m,Element) * sJ(k,l,m,Element)/(wGP(k)*wGP(l)*wGP(m))
#else
      source(4,k,l,m,Element) = source(4,k,l,m,Element) * sJ(k,l,m,Element)/(wGP(k)*wGP(l)*wGP(m))
#endif
    END DO; END DO; END DO
  END DO
CASE('cartmesh_volumeweighting')
  ! Step 1: Deposition of all particles onto background mesh -> densities
  ALLOCATE(BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4))
  BGMSource(:,:,:,:) = 0.0
  DO i = firstPart, lastPart
    IF (PDM%ParticleInside(i)) THEN
      Charge = Species(PartSpecies(i))%ChargeIC*Species(PartSpecies(i))%MacroParticleFactor
      k = FLOOR(PartState(i,1)/BGMdeltas(1))
      l = FLOOR(PartState(i,2)/BGMdeltas(2))
      m = FLOOR(PartState(i,3)/BGMdeltas(3))
      alpha1 = (PartState(i,1) / BGMdeltas(1)) - k
      alpha2 = (PartState(i,2) / BGMdeltas(2)) - l
      alpha3 = (PartState(i,3) / BGMdeltas(3)) - m
      TSource(:) = 0.0
#if (PP_nVar==8)
      TSource(1) = PartState(i,4)*Charge
      TSource(2) = PartState(i,5)*Charge
      TSource(3) = PartState(i,6)*Charge
#endif
      TSource(4) = Charge

      BGMSource(k,l,m,1:4)       = BGMSource(k,l,m,1:4) + (TSource * (1-alpha1)*(1-alpha2)*(1-alpha3))
      BGMSource(k,l,m+1,1:4)     = BGMSource(k,l,m+1,1:4) + (TSource * (1-alpha1)*(1-alpha2)*(alpha3))
      BGMSource(k,l+1,m,1:4)     = BGMSource(k,l+1,m,1:4) + (TSource * (1-alpha1)*(alpha2)*(1-alpha3))
      BGMSource(k,l+1,m+1,1:4)   = BGMSource(k,l+1,m+1,1:4) + (TSource * (1-alpha1)*(alpha2)*(alpha3))
      BGMSource(k+1,l,m,1:4)     = BGMSource(k+1,l,m,1:4) + (TSource * (alpha1)*(1-alpha2)*(1-alpha3))
      BGMSource(k+1,l,m+1,1:4)   = BGMSource(k+1,l,m+1,1:4) + (TSource * (alpha1)*(1-alpha2)*(alpha3))
      BGMSource(k+1,l+1,m,1:4)   = BGMSource(k+1,l+1,m,1:4) + (TSource * (alpha1)*(alpha2)*(1-alpha3))
      BGMSource(k+1,l+1,m+1,1:4) = BGMSource(k+1,l+1,m+1,1:4) + (TSource * (alpha1)*(alpha2)*(alpha3))
    END IF
  END DO
  BGMSource(:,:,:,:) = BGMSource(:,:,:,:) / BGMVolume

#ifdef MPI
  CALL MPISourceExchangeBGM(BGMSource)
#else
  IF (GEO%nPeriodicVectors.GT.0) CALL PeriodicSourceExchange(BGMSource)
#endif

  ! Step 2: Interpolation of densities onto grid
  DO iElem = 1, nElems
    DO kk = 0, PP_N
      DO ll = 0, PP_N
        DO mm = 0, PP_N
         k = GaussBGMIndex(1,kk,ll,mm,iElem)
         l = GaussBGMIndex(2,kk,ll,mm,iElem)
         m = GaussBGMIndex(3,kk,ll,mm,iElem)
         alpha1 = GaussBGMFactor(1,kk,ll,mm,iElem)
         alpha2 = GaussBGMFactor(2,kk,ll,mm,iElem)
         alpha3 = GaussBGMFactor(3,kk,ll,mm,iElem)
#if (PP_nVar==8)
         DO i = 1,3
           source(i,kk,ll,mm,iElem) = BGMSource(k,l,m,i) * (1-alpha1) * (1-alpha2) * (1-alpha3) + &
                BGMSource(k,l,m+1,i) * (1-alpha1) * (1-alpha2) * (alpha3) + &
                BGMSource(k,l+1,m,i) * (1-alpha1) * (alpha2) * (1-alpha3) + &
                BGMSource(k,l+1,m+1,i) * (1-alpha1) * (alpha2) * (alpha3) + &
                BGMSource(k+1,l,m,i) * (alpha1) * (1-alpha2) * (1-alpha3) + &
                BGMSource(k+1,l,m+1,i) * (alpha1) * (1-alpha2) * (alpha3) + &
                BGMSource(k+1,l+1,m,i) * (alpha1) * (alpha2) * (1-alpha3) + &
                BGMSource(k+1,l+1,m+1,i) * (alpha1) * (alpha2) * (alpha3)
         END DO
#endif
         source(4,kk,ll,mm,iElem) = BGMSource(k,l,m,4) * (1-alpha1) * (1-alpha2) * (1-alpha3) + &
              BGMSource(k,l,m+1,4) * (1-alpha1) * (1-alpha2) * (alpha3) + &
              BGMSource(k,l+1,m,4) * (1-alpha1) * (alpha2) * (1-alpha3) + &
              BGMSource(k,l+1,m+1,4) * (1-alpha1) * (alpha2) * (alpha3) + &
              BGMSource(k+1,l,m,4) * (alpha1) * (1-alpha2) * (1-alpha3) + &
              BGMSource(k+1,l,m+1,4) * (alpha1) * (1-alpha2) * (alpha3) + &
              BGMSource(k+1,l+1,m,4) * (alpha1) * (alpha2) * (1-alpha3) + &
              BGMSource(k+1,l+1,m+1,4) * (alpha1) * (alpha2) * (alpha3)
       END DO !mm
     END DO !ll
   END DO !kk
 END DO !iElem
 DEALLOCATE(BGMSource)
CASE('cartmesh_splines')
  ! Step 1: Deposition of all particles onto background mesh -> densities
  ALLOCATE(BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4))
  BGMSource(:,:,:,:) = 0.0
  DO i = firstPart, lastPart
    IF (PDM%ParticleInside(i)) THEN
      Charge = Species(PartSpecies(i))%ChargeIC*Species(PartSpecies(i))%MacroParticleFactor
      PosInd(1) = FLOOR(PartState(i,1)/BGMdeltas(1))
      PosInd(2) = FLOOR(PartState(i,2)/BGMdeltas(2))
      PosInd(3) = FLOOR(PartState(i,3)/BGMdeltas(3))
      DO dir = 1,3               ! x,y,z direction
        DO weightrun = 0,3
          DO mm = 0, 3
            IF (mm.EQ.weightrun) then
              auxiliary(mm) = 1.0
            ELSE
              auxiliary(mm) = 0.0
            END IF
          END DO
          CALL DeBoor(PosInd(dir),auxiliary,PartState(i,dir),weight(dir,weightrun),dir)
        END DO
      END DO
      DO k = PosInd(1)-1, PosInd(1)+2
        kk = abs(k - PosInd(1) - 2)
        DO l = PosInd(2)-1, PosInd(2)+2
          ll = abs(l - PosInd(2) - 2)
          DO m = PosInd(3)-1, PosInd(3)+2
            mm = abs(m - PosInd(3) - 2)
            locweight = weight(1,kk)*weight(2,ll)*weight(3,mm)
#if (PP_nVar==8)
            BGMSource(k,l,m,1) = BGMSource(k,l,m,1) + PartState(i,4)*Charge * locweight
            BGMSource(k,l,m,2) = BGMSource(k,l,m,2) + PartState(i,5)*Charge * locweight
            BGMSource(k,l,m,3) = BGMSource(k,l,m,3) + PartState(i,6)*Charge * locweight
#endif
            BGMSource(k,l,m,4) = BGMSource(k,l,m,4) + Charge * locweight
          END DO
        END DO
      END DO
    END IF
  END DO
  BGMSource(:,:,:,:) = BGMSource(:,:,:,:) / BGMVolume

#ifdef MPI
  CALL MPISourceExchangeBGM(BGMSource)
#else
  IF (GEO%nPeriodicVectors.GT.0) CALL PeriodicSourceExchange(BGMSource)
#endif

  ! Step 2: Interpolation of densities onto grid
  DO iElem = 1, nElems
    DO kk = 0, PP_N
      DO ll = 0, PP_N
        DO mm = 0, PP_N
          k = GaussBGMIndex(1,kk,ll,mm,iElem)
          l = GaussBGMIndex(2,kk,ll,mm,iElem)
          m = GaussBGMIndex(3,kk,ll,mm,iElem)
          DO r = k-1,k+2
            u = r-k+2
            DO ss = l-1,l+2
              v = ss-l+2
              DO t = m-1,m+2
                w = t-m+2
#if (PP_nVar==8)                  
                DO i = 1,3
                  source(i,kk,ll,mm,iElem) = source(i,kk,ll,mm,iElem) + BGMSource(r,ss,t,i) * GPWeight(iElem,kk,ll,mm,u,v,w)
                END DO
#endif
                source(4,kk,ll,mm,iElem) = source(4,kk,ll,mm,iElem) + BGMSource(r,ss,t,4) * GPWeight(iElem,kk,ll,mm,u,v,w)
              END DO !t
            END DO !s
          END DO !r
        END DO !mm
      END DO !ll
    END DO !kk
  END DO !iElem
 DEALLOCATE(BGMSource)
CASE DEFAULT
  CALL abort(__STAMP__, &
       'Unknown DepositionType in pic_depo.f90')
END SELECT

RETURN
END SUBROUTINE Deposition


SUBROUTINE DepositionMPF()  
!============================================================================================================================
! This subroutine performes the deposition of the particle charge and current density to the grid in the MPF case
! following list of distribution methods are implemted
! - nearest blurrycenter (barycenter of hexahedra)
! - nearest Gauss Point  (only volome of IP - higher resolution than nearest blurrycenter )
! - shape function       (only one type implemented)
!============================================================================================================================
! use MODULES                                                                          
USE MOD_PICDepo_Vars
USE MOD_Particle_Vars
USE MOD_PreProc
USE MOD_Mesh_Vars,     ONLY : nElems, Elem_xGP, sJ
USE MOD_Globals
USE MOD_part_MPI_Vars, ONLY : casematrix, NbrOfCases
USE MOD_Interpolation_Vars, ONLY : wGP
USE MOD_PICInterpolation_Vars, ONLY : InterpolationType
USE MOD_Eval_xyz,            ONLY:Eval_XYZ_ElemCheck
#ifdef MPI
USE MOD_Particle_MPI_Vars, ONLY: PartMPI
!USE MOD_part_MPI_Vars, ONLY : ExtPartState, ExtPartSpecies, NbrOfextParticles, PMPIVAR
#endif 
!--------------------------------------------------------------------------------------------------!
  IMPLICIT NONE                                                                                  
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
  INTEGER                          :: i, k, l, m, Element, iElem                            
  LOGICAL                          :: chargedone(1:nElems), SAVE_GAUSS             
  INTEGER                          :: kmin, kmax, lmin, lmax, mmin, mmax                           
  INTEGER                          :: kk, ll, mm, ppp                                              
  INTEGER                          :: ElemID, iCase, ind
  REAL                             :: radius, S, S1, Fac(4)
  REAL                             :: Vec1(1:3), Vec2(1:3), Vec3(1:3), ShiftedPart(1:3)
  INTEGER                          :: a,b, ii, expo
  REAL                             :: ElemSource(nElems,1:4)
  REAL, ALLOCATABLE                :: BGMSource(:,:,:,:)
  REAL                             :: Charge, TSource(1:4), auxiliary(0:3),weight(1:3,0:3), locweight
  REAL                             :: alpha1, alpha2, alpha3
  INTEGER                          :: PosInd(3),r,ss,t,u,v,w, dir, weightrun
#ifdef MPI
  INTEGER                           ::iPart
#endif
!--------------------------------------------------------------------------------------------------!
  source=0.0

  SELECT CASE(TRIM(DepositionType))
  CASE('nearest_blurrycenter')
    ElemSource=0.0
    DO i=1,PDM%ParticleVecLength
      IF (PDM%ParticleInside(i)) THEN
        Element = PEM%Element(i)
#if (PP_nVar==8)
        ElemSource(Element,1:3) = ElemSource(Element,1:3)+ &
             PartState(i,4:6)* Species(PartSpecies(i))%ChargeIC * PartMPF(i)
#endif
        ElemSource(Element,4) = ElemSource(Element,4) + & 
             Species(PartSpecies(i))%ChargeIC* PartMPF(i)
      END IF
    END DO
    DO Element=1,nElems
#if (PP_nVar==8)
      source(1,:,:,:,Element) = ElemSource(Element,1)
      source(2,:,:,:,Element) = ElemSource(Element,2)
      source(3,:,:,:,Element) = ElemSource(Element,3)
#endif
      source(4,:,:,:,Element) = ElemSource(Element,4)
    END DO
    DO Element=1,nElems
#if (PP_nVar==8)
      source(1:4,:,:,:,Element) = source(1:4,:,:,:,Element) / GEO%Volume(Element)
#else
      source(4,:,:,:,Element) = source(4,:,:,:,Element) / GEO%Volume(Element)
#endif
    END DO
  CASE('shape_function')
    !Vec1(1:3) = 0.
    !Vec2(1:3) = 0.
    !Vec3(1:3) = 0.
    !IF (GEO%nPeriodicVectors.EQ.1) THEN
      !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
    !END IF
    !IF (GEO%nPeriodicVectors.EQ.2) THEN
      !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
      !Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
    !END IF
    !IF (GEO%nPeriodicVectors.EQ.3) THEN
      !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
      !Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
      !Vec3(1:3) = GEO%PeriodicVectors(1:3,3)
    !END IF
    !DO i=1,PDM%ParticleVecLength
      !IF (PDM%ParticleInside(i)) THEN
        !Fac(4) = Species(PartSpecies(i))%ChargeIC *PartMPF(i)*w_sf
        !Fac(1:3) = PartState(i,4:6)*Fac(4)
        !!-- determine which background mesh cells (and interpolation points within) need to be considered
        !DO iCase = 1, NbrOfCases
          !chargedone(:) = .FALSE.
          !DO ind = 1,3
            !ShiftedPart(ind) = PartState(i,ind) + casematrix(iCase,1)*Vec1(ind) + &
                 !casematrix(iCase,2)*Vec2(ind) + casematrix(iCase,3)*Vec3(ind)
          !END DO
          !kmax = CEILING((ShiftedPart(1)+r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1))
          !kmax = MIN(kmax,GEO%FIBGMimax)
          !kmin = FLOOR((ShiftedPart(1)-r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1)+1)
          !kmin = MAX(kmin,GEO%FIBGMimin)
          !lmax = CEILING((ShiftedPart(2)+r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2))
          !lmax = MIN(lmax,GEO%FIBGMkmax)
          !lmin = FLOOR((ShiftedPart(2)-r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2)+1)
          !lmin = MAX(lmin,GEO%FIBGMkmin)
          !mmax = CEILING((ShiftedPart(3)+r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3))
          !mmax = MIN(mmax,GEO%FIBGMlmax)
          !mmin = FLOOR((ShiftedPart(3)-r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3)+1)
          !mmin = MAX(mmin,GEO%FIBGMlmin)
          !!-- go through all these cells
          !DO kk = kmin,kmax
            !DO ll = lmin, lmax
              !DO mm = mmin, mmax
                !!--- go through all mapped elements not done yet
                !DO ppp = 1,GEO%FIBGM(kk,ll,mm)%nElem
                  !ElemID = GEO%FIBGM(kk,ll,mm)%Element(ppp)
                  !IF (.NOT.chargedone(ElemID)) THEN
                    !!--- go through all gauss points
                    !DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
                      !!-- calculate distance between gauss and particle
                      !radius = (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) * (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) &
                             !+ (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) * (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) &
                             !+ (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID)) * (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID))
                      !!-- calculate charge and current density at ip point using a shape function
                      !!-- currently only one shapefunction available, more to follow (including structure change)
                      !IF (radius .LT. r2_sf) THEN
                        !S = 1 - r2_sf_inv * radius
                        !S1 = S*S
                        !DO expo = 3, alpha_sf
                          !S1 = S*S1
                        !END DO
!#if (PP_nVar==8)
                        !source(1:3,k,l,m,ElemID) = source(1:3,k,l,m,ElemID) + Fac(1:3) * S1
!#endif
                        !source( 4 ,k,l,m,ElemID) = source( 4 ,k,l,m,ElemID) + Fac(4) * S1
                      !END IF
                    !END DO; END DO; END DO
                    !chargedone(ElemID) = .TRUE.
                  !END IF
                !END DO ! ppp
              !END DO ! mm
            !END DO ! ll
          !END DO ! kk
        !END DO ! iCase (periodicity)
      !END IF ! inside
    !END DO ! i

!#ifdef MPI           
!IF (PMPIVAR%nProcs.GT.1) THEN
  !SWRITE(*,*) 'Shape Function MPI does not work with vMPF with more than one proc!'
  !SWRITE(*,*) 'Reason: MPF of particles outside of proc domain'
  !SWRITE(*,*) '(but still in shape function range) is not communicated yet.'
  !CALL abort(__STAMP__, &
        !'Shape Function MPI does not work with vMPF with more than one proc!')
!END IF
    !Vec1(1:3) = 0.
    !Vec2(1:3) = 0.
    !Vec3(1:3) = 0.
    !IF (NbrOfextParticles .GT. 0) THEN
      !IF (GEO%nPeriodicVectors.EQ.1) THEN
        !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
      !END IF
      !IF (GEO%nPeriodicVectors.EQ.2) THEN
        !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
        !Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
      !END IF
      !IF (GEO%nPeriodicVectors.EQ.3) THEN
        !Vec1(1:3) = GEO%PeriodicVectors(1:3,1)
        !Vec2(1:3) = GEO%PeriodicVectors(1:3,2)
        !Vec3(1:3) = GEO%PeriodicVectors(1:3,3)
      !END IF
    !END IF
    
    !DO iPart=1,NbrOfextParticles  !external Particles
      !chargedone(:) = .FALSE.
      !Fac(4) = Species(ExtPartSpecies(iPart))%ChargeIC*PartMPF(i)*w_sf
      !Fac(1:3) = ExtPartState(iPart,4:6)*Fac(4)
      !!-- determine which background mesh cells (and interpolation points within) need to be considered
      !DO iCase = 1, NbrOfCases
        !DO ind = 1,3
          !ShiftedPart(ind) = ExtPartState(iPart,ind) + casematrix(iCase,1)*Vec1(ind) + &
               !casematrix(iCase,2)*Vec2(ind) + casematrix(iCase,3)*Vec3(ind)
        !END DO
        !kmax = CEILING((ShiftedPart(1)+r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1))
        !kmax = MIN(kmax,GEO%FIBGMimax)
        !kmin = FLOOR((ShiftedPart(1)-r_sf-GEO%xminglob)/GEO%FIBGMdeltas(1)+1)
        !kmin = MAX(kmin,GEO%FIBGMimin)
        !lmax = CEILING((ShiftedPart(2)+r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2))
        !lmax = MIN(lmax,GEO%FIBGMkmax)
        !lmin = FLOOR((ShiftedPart(2)-r_sf-GEO%yminglob)/GEO%FIBGMdeltas(2)+1)
        !lmin = MAX(lmin,GEO%FIBGMkmin)
        !mmax = CEILING((ShiftedPart(3)+r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3))
        !mmax = MIN(mmax,GEO%FIBGMlmax)
        !mmin = FLOOR((ShiftedPart(3)-r_sf-GEO%zminglob)/GEO%FIBGMdeltas(3)+1)
        !mmin = MAX(mmin,GEO%FIBGMlmin)
        !!-- go through all these cells (should go through non if periodic and shiftedpart not in my domain
        !DO kk = kmin,kmax
          !DO ll = lmin, lmax
            !DO mm = mmin, mmax
              !!--- go through all mapped elements not done yet
              !DO ppp = 1,GEO%FIBGM(kk,ll,mm)%nElem
                !ElemID = GEO%FIBGM(kk,ll,mm)%Element(ppp)
                !IF (.NOT.chargedone(ElemID)) THEN
                  !!--- go through all gauss points
                  !DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
                    !!-- calculate distance between gauss and particle
                      !radius = (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) * (ShiftedPart(1) - Elem_xGP(1,k,l,m,ElemID)) &
                             !+ (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) * (ShiftedPart(2) - Elem_xGP(2,k,l,m,ElemID)) &
                             !+ (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID)) * (ShiftedPart(3) - Elem_xGP(3,k,l,m,ElemID))
                      !!-- calculate charge and current density at ip point using a shape function
                      !!-- currently only one shapefunction available, more to follow (including structure change)
                      !IF (radius .LT. r2_sf) THEN
                        !S = 1 - r2_sf_inv * radius
                        !S1 = S*S
                        !DO expo = 3, alpha_sf
                          !S1 = S*S1
                        !END DO
!#if (PP_nVar==8)
                        !source(1:3,k,l,m,ElemID) = source(1:3,k,l,m,ElemID) + Fac(1:3) * S1
!#endif
                        !source( 4 ,k,l,m,ElemID) = source( 4 ,k,l,m,ElemID) + Fac(4) * S1
                      !END IF
                  !END DO; END DO; END DO
                  !chargedone(ElemID) = .TRUE.
                !END IF
              !END DO ! ppp
            !END DO ! mm
          !END DO ! ll
        !END DO ! kk
      !END DO
    !END DO
    !SDEALLOCATE(ExtPartState)
    !SDEALLOCATE(ExtPartSpecies)
!#endif
  CASE('nearest_gausspoint')
    SAVE_GAUSS = .FALSE.
    IF(TRIM(InterpolationType).EQ.'nearest_gausspoint') SAVE_GAUSS = .TRUE.
    IF(MOD(PP_N,2).EQ.0) THEN
      a = PP_N/2
      b = a
    ELSE
      a = (PP_N+1)/2
      b = a-1
    END IF
    DO i=1,PDM%ParticleVecLength
      IF (PDM%ParticleInside(i)) THEN
        Element = PEM%Element(i)
        ! Map Particle to -1|1 space (re-used in interpolation)
        CALL Eval_XYZ_ElemCheck(PartState(i,1:3),PartPosMapped(i,1:3),Element)
        ! Find out which gausspoint is closest and add up charges and currents
        !! x-direction
        k = a
        DO ii = 0,b-1
          IF(ABS(PartPosMapped(i,1)).GE.GaussBorder(PP_N-ii))THEN
            k = PP_N-ii
            EXIT
          END IF
        END DO
        k = NINT((PP_N+SIGN(2.0*k-PP_N,PartPosMapped(i,1)))/2)
        !! y-direction
        l = a
        DO ii = 0,b-1
          IF(ABS(PartPosMapped(i,2)).GE.GaussBorder(PP_N-ii))THEN
            l = PP_N-ii
            EXIT
          END IF
        END DO
        l = NINT((PP_N+SIGN(2.0*l-PP_N,PartPosMapped(i,2)))/2)
        !! z-direction
        m = a
        DO ii = 0,b-1
          IF(ABS(PartPosMapped(i,3)).GE.GaussBorder(PP_N-ii))THEN
            m = PP_N-ii
            EXIT
          END IF
        END DO
        m = NINT((PP_N+SIGN(2.0*m-PP_N,PartPosMapped(i,3)))/2)
#if (PP_nVar==8)
        source(1:3,k,l,m,Element) = source(1:3,k,l,m,Element) + PartState(i,4:6) & !* Species(PartSpecies(i))%ChargeIC
                                               * Species(PartSpecies(i))%ChargeIC &
                                               * PartMPF(i)
#endif
        source( 4 ,k,l,m,Element) = source( 4 ,k,l,m,Element) & !Species(PartSpecies(i))%ChargeIC
                                               + Species(PartSpecies(i))%ChargeIC &
                                               * PartMPF(i)
        IF (SAVE_GAUSS) THEN
          PartPosGauss(i,1) = k
          PartPosGauss(i,2) = l
          PartPosGauss(i,3) = m
        END IF
      END IF
    END DO
    DO Element=1,nElems
      DO m=0,PP_N; DO l=0,PP_N; DO k=0,PP_N
        !get densities by dividing by pseudo gauss volume
#if (PP_nVar==8)
        source(1:4,k,l,m,Element) = source(1:4,k,l,m,Element) * sJ(k,l,m,Element)/(wGP(k)*wGP(l)*wGP(m))
#else
        source(4,k,l,m,Element) = source(4,k,l,m,Element) * sJ(k,l,m,Element)/(wGP(k)*wGP(l)*wGP(m))
#endif
      END DO; END DO; END DO
    END DO
  CASE('cartmesh_volumeweighting')
    ! Step 1: Deposition of all particles onto background mesh -> densities
    ALLOCATE(BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4))
    BGMSource(:,:,:,:) = 0.0
    DO i = 1, PDM%ParticleVecLength
      IF (PDM%ParticleInside(i)) THEN
        Charge = Species(PartSpecies(i))%ChargeIC * PartMPF(i)
        k = FLOOR(PartState(i,1)/BGMdeltas(1))
        l = FLOOR(PartState(i,2)/BGMdeltas(2))
        m = FLOOR(PartState(i,3)/BGMdeltas(3))
        alpha1 = (PartState(i,1) / BGMdeltas(1)) - k
        alpha2 = (PartState(i,2) / BGMdeltas(2)) - l
        alpha3 = (PartState(i,3) / BGMdeltas(3)) - m
        TSource(:) = 0.0
#if (PP_nVar==8)
        TSource(1) = PartState(i,4)*Charge
        TSource(2) = PartState(i,5)*Charge
        TSource(3) = PartState(i,6)*Charge
#endif
        TSource(4) = Charge

        BGMSource(k,l,m,1:4)       = BGMSource(k,l,m,1:4) + (TSource * (1-alpha1)*(1-alpha2)*(1-alpha3))
        BGMSource(k,l,m+1,1:4)     = BGMSource(k,l,m+1,1:4) + (TSource * (1-alpha1)*(1-alpha2)*(alpha3))
        BGMSource(k,l+1,m,1:4)     = BGMSource(k,l+1,m,1:4) + (TSource * (1-alpha1)*(alpha2)*(1-alpha3))
        BGMSource(k,l+1,m+1,1:4)   = BGMSource(k,l+1,m+1,1:4) + (TSource * (1-alpha1)*(alpha2)*(alpha3))
        BGMSource(k+1,l,m,1:4)     = BGMSource(k+1,l,m,1:4) + (TSource * (alpha1)*(1-alpha2)*(1-alpha3))
        BGMSource(k+1,l,m+1,1:4)   = BGMSource(k+1,l,m+1,1:4) + (TSource * (alpha1)*(1-alpha2)*(alpha3))
        BGMSource(k+1,l+1,m,1:4)   = BGMSource(k+1,l+1,m,1:4) + (TSource * (alpha1)*(alpha2)*(1-alpha3))
        BGMSource(k+1,l+1,m+1,1:4) = BGMSource(k+1,l+1,m+1,1:4) + (TSource * (alpha1)*(alpha2)*(alpha3))
      END IF
    END DO
    BGMSource(:,:,:,:) = BGMSource(:,:,:,:) / BGMVolume

#ifdef MPI
    CALL MPISourceExchangeBGM(BGMSource)
#else
    IF (GEO%nPeriodicVectors.GT.0) CALL PeriodicSourceExchange(BGMSource)
#endif

    ! Step 2: Interpolation of densities onto grid
    DO iElem = 1, nElems
      DO kk = 0, PP_N
        DO ll = 0, PP_N
          DO mm = 0, PP_N
           k = GaussBGMIndex(1,kk,ll,mm,iElem)
           l = GaussBGMIndex(2,kk,ll,mm,iElem)
           m = GaussBGMIndex(3,kk,ll,mm,iElem)
           alpha1 = GaussBGMFactor(1,kk,ll,mm,iElem)
           alpha2 = GaussBGMFactor(2,kk,ll,mm,iElem)
           alpha3 = GaussBGMFactor(3,kk,ll,mm,iElem)
#if (PP_nVar==8)
           DO i = 1,3
             source(i,kk,ll,mm,iElem) = BGMSource(k,l,m,i) * (1-alpha1) * (1-alpha2) * (1-alpha3) + &
                  BGMSource(k,l,m+1,i) * (1-alpha1) * (1-alpha2) * (alpha3) + &
                  BGMSource(k,l+1,m,i) * (1-alpha1) * (alpha2) * (1-alpha3) + &
                  BGMSource(k,l+1,m+1,i) * (1-alpha1) * (alpha2) * (alpha3) + &
                  BGMSource(k+1,l,m,i) * (alpha1) * (1-alpha2) * (1-alpha3) + &
                  BGMSource(k+1,l,m+1,i) * (alpha1) * (1-alpha2) * (alpha3) + &
                  BGMSource(k+1,l+1,m,i) * (alpha1) * (alpha2) * (1-alpha3) + &
                  BGMSource(k+1,l+1,m+1,i) * (alpha1) * (alpha2) * (alpha3)
           END DO
#endif
           source(4,kk,ll,mm,iElem) = BGMSource(k,l,m,4) * (1-alpha1) * (1-alpha2) * (1-alpha3) + &
                BGMSource(k,l,m+1,4) * (1-alpha1) * (1-alpha2) * (alpha3) + &
                BGMSource(k,l+1,m,4) * (1-alpha1) * (alpha2) * (1-alpha3) + &
                BGMSource(k,l+1,m+1,4) * (1-alpha1) * (alpha2) * (alpha3) + &
                BGMSource(k+1,l,m,4) * (alpha1) * (1-alpha2) * (1-alpha3) + &
                BGMSource(k+1,l,m+1,4) * (alpha1) * (1-alpha2) * (alpha3) + &
                BGMSource(k+1,l+1,m,4) * (alpha1) * (alpha2) * (1-alpha3) + &
                BGMSource(k+1,l+1,m+1,4) * (alpha1) * (alpha2) * (alpha3)
         END DO !mm
       END DO !ll
     END DO !kk
   END DO !iElem
   DEALLOCATE(BGMSource)
  CASE('cartmesh_splines')
    ! Step 1: Deposition of all particles onto background mesh -> densities
    ALLOCATE(BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4))
    BGMSource(:,:,:,:) = 0.0
    DO i = 1, PDM%ParticleVecLength
      IF (PDM%ParticleInside(i)) THEN
        Charge = Species(PartSpecies(i))%ChargeIC * PartMPF(i)
        PosInd(1) = FLOOR(PartState(i,1)/BGMdeltas(1))
        PosInd(2) = FLOOR(PartState(i,2)/BGMdeltas(2))
        PosInd(3) = FLOOR(PartState(i,3)/BGMdeltas(3))
        DO dir = 1,3               ! x,y,z direction
          DO weightrun = 0,3
            DO mm = 0, 3
              IF (mm.EQ.weightrun) then
                auxiliary(mm) = 1.0
              ELSE
                auxiliary(mm) = 0.0
              END IF
            END DO
            CALL DeBoor(PosInd(dir),auxiliary,PartState(i,dir),weight(dir,weightrun),dir)
          END DO
        END DO
        DO k = PosInd(1)-1, PosInd(1)+2
          kk = abs(k - PosInd(1) - 2)
          DO l = PosInd(2)-1, PosInd(2)+2
            ll = abs(l - PosInd(2) - 2)
            DO m = PosInd(3)-1, PosInd(3)+2
              mm = abs(m - PosInd(3) - 2)
              locweight = weight(1,kk)*weight(2,ll)*weight(3,mm)
#if (PP_nVar==8)
              BGMSource(k,l,m,1) = BGMSource(k,l,m,1) + PartState(i,4)*Charge * locweight
              BGMSource(k,l,m,2) = BGMSource(k,l,m,2) + PartState(i,5)*Charge * locweight
              BGMSource(k,l,m,3) = BGMSource(k,l,m,3) + PartState(i,6)*Charge * locweight
#endif
              BGMSource(k,l,m,4) = BGMSource(k,l,m,4) + Charge * locweight
            END DO
          END DO
        END DO
      END IF
    END DO
    BGMSource(:,:,:,:) = BGMSource(:,:,:,:) / BGMVolume

#ifdef MPI
    CALL MPISourceExchangeBGM(BGMSource)
#else
    IF (GEO%nPeriodicVectors.GT.0) CALL PeriodicSourceExchange(BGMSource)
#endif

    ! Step 2: Interpolation of densities onto grid
    DO iElem = 1, nElems
      DO kk = 0, PP_N
        DO ll = 0, PP_N
          DO mm = 0, PP_N
            k = GaussBGMIndex(1,kk,ll,mm,iElem)
            l = GaussBGMIndex(2,kk,ll,mm,iElem)
            m = GaussBGMIndex(3,kk,ll,mm,iElem)
            DO r = k-1,k+2
              u = r-k+2
              DO ss = l-1,l+2
                v = ss-l+2
                DO t = m-1,m+2
                  w = t-m+2
#if (PP_nVar==8)                  
                  DO i = 1,3
                    source(i,kk,ll,mm,iElem) = source(i,kk,ll,mm,iElem) + BGMSource(r,ss,t,i) * GPWeight(iElem,kk,ll,mm,u,v,w)
                  END DO
#endif
                  source(4,kk,ll,mm,iElem) = source(4,kk,ll,mm,iElem) + BGMSource(r,ss,t,4) * GPWeight(iElem,kk,ll,mm,u,v,w)
                END DO !t
              END DO !s
            END DO !r
          END DO !mm
        END DO !ll
      END DO !kk
    END DO !iElem
   DEALLOCATE(BGMSource)
  CASE DEFAULT
    CALL abort(__STAMP__, &
        'Unknown DepositionType in pic_depo.f90')
  END SELECT
 RETURN
END SUBROUTINE DepositionMPF

#ifndef MPI
SUBROUTINE PeriodicSourceExchange(BGMSource)    
!============================================================================================================================
! Exchange sources in periodic case
!============================================================================================================================
! use MODULES                                                    
  USE MOD_part_MPI_Vars
  USE MOD_PICDepo_Vars
  USE MOD_Particle_Vars
!-----------------------------------------------------------------------------------------------------------------------------------
    IMPLICIT NONE                                                                                  
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
    REAL,INTENT(INOUT)         :: BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4)
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES                                                                           
    INTEGER                     :: i,k,l,m,k2,l2,m2
!-----------------------------------------------------------------------------------------------------------------------------------

DO i = 1,GEO%nPeriodicVectors
  DO k = BGMminX, BGMmaxX
    k2 = k + GEO%PeriodicBGMVectors(1,i)
    DO l = BGMminY, BGMmaxY
      l2 = l + GEO%PeriodicBGMVectors(2,i)
      DO m = BGMminZ, BGMmaxZ
        m2 = m + GEO%PeriodicBGMVectors(3,i)
        IF ((k2.GE.BGMminX).AND.(k2.LE.BGMmaxX)) THEN
          IF ((l2.GE.BGMminY).AND.(l2.LE.BGMmaxY)) THEN
            IF ((m2.GE.BGMminZ).AND.(m2.LE.BGMmaxZ)) THEN
              BGMSource(k,l,m,:) = BGMSource(k,l,m,:) + BGMSource(k2,l2,m2,:)
              BGMSource(k2,l2,m2,:) = BGMSource(k,l,m,:)
            END IF
          END IF
        END IF
      END DO
    END DO
  END DO
END DO
RETURN
END SUBROUTINE PeriodicSourceExchange
#else /*MPI*/
SUBROUTINE MPISourceExchangeBGM(BGMSource)            
!============================================================================================================================
! Exchange sources in periodic case for MPI
!============================================================================================================================
! use MODULES                                                         
  USE MOD_Particle_MPI_Vars, ONLY: PartMPI
  USE MOD_PICDepo_Vars
  USE MOD_Globals
  USE MOD_Particle_Vars
!-----------------------------------------------------------------------------------------------------------------------------------
    IMPLICIT NONE                                                                                  
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
    REAL,INTENT(INOUT)        :: BGMSource(BGMminX:BGMmaxX,BGMminY:BGMmaxY,BGMminZ:BGMmaxZ,1:4)
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES 
    !TYPE(tMPIMessage)           :: send_message(0:PartMPI%nProcs-1)                              
    !TYPE(tMPIMessage)           :: recv_message(0:PartMPI%nProcs-1)                              
    !INTEGER                     :: send_request(0:PartMPI%nProcs-1)                              
    !INTEGER                     :: recv_request(0:PartMPI%nProcs-1)                              
    !INTEGER                     :: send_status_list(1:MPI_STATUS_SIZE,0:PartMPI%nProcs-1)        
    !INTEGER                     :: recv_status_list(1:MPI_STATUS_SIZE,0:PartMPI%nProcs-1)        
    !INTEGER                     :: i,k,l,m,n, ppp, Counter, MsgLength(0:PartMPI%nProcs-1)        
    !INTEGER                     :: SourceLength(0:PartMPI%nProcs-1)                              
    !INTEGER                     :: RecvLength(0:PartMPI%nProcs-1)                                
    !INTEGER                     :: allocStat, Counter2                                     
    !INTEGER                     :: messageCounterS, messageCounterR                                
    !INTEGER                     :: myRealKind, k2,l2,m2                                          
    !REAL                        :: myRealTestValue                                                
!-----------------------------------------------------------------------------------------------------------------------------------

     !myRealKind = KIND(myRealTestValue)
     !IF (myRealKind.EQ.4) THEN
       !myRealKind = MPI_REAL
     !ELSE IF (myRealKind.EQ.8) THEN
       !myRealKind = MPI_DOUBLE_PRECISION
     !ELSE
       !myRealKind = MPI_REAL
     !END IF
     
   !!--- Determine which Sources actually need to be sent (<> 0) and build corresponding true/false list
   !!    One list per process
    !DO i = 0,PartMPI%nProcs-1
       !MsgLength(i) = 0
       !IF (PartMPI%MPIConnect(i)%isBGMNeighbor) THEN
          !MsgLength(i) = (PMPIVAR%MPIConnect(i)%BGMBorder(2,1) - PMPIVAR%MPIConnect(i)%BGMBorder(1,1) + 1) * &
                         !(PMPIVAR%MPIConnect(i)%BGMBorder(2,2) - PMPIVAR%MPIConnect(i)%BGMBorder(1,2) + 1) * &
                         !(PMPIVAR%MPIConnect(i)%BGMBorder(2,3) - PMPIVAR%MPIConnect(i)%BGMBorder(1,3) + 1)
       !END IF
       !IF(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor) THEN
          !DO k = 1, PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount
             !MsgLength(i) = MsgLength(i) + &
                  !(PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(2,1) -&
                   !PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(1,1) + 1) * &
                  !(PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(2,2) -&
                   !PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(1,2) + 1) * &
                  !(PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(2,3) -&
                   !PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(1,3) + 1)
          !END DO
       !END IF
       !IF((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor))THEN
          !ALLOCATE(send_message(i)%content_log(1:MsgLength(i)), STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
                !'ERROR in MPISourceExchangeBGM: cannot allocate send_message')
          !END IF
          !ALLOCATE(recv_message(i)%content_log(1:MsgLength(i)), STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
                !'ERROR in MPISourceExchangeBGM: cannot allocate recv_message')
          !END IF
       !END IF
       !!--- check which sources are <> 0
       !Counter = 0
       !SourceLength(i) = 0
       !IF (PMPIVAR%MPIConnect(i)%isBGMNeighbor) THEN
          !DO k = PMPIVAR%MPIConnect(i)%BGMBorder(1,1), PMPIVAR%MPIConnect(i)%BGMBorder(2,1)
          !DO l = PMPIVAR%MPIConnect(i)%BGMBorder(1,2), PMPIVAR%MPIConnect(i)%BGMBorder(2,2)
          !DO m = PMPIVAR%MPIConnect(i)%BGMBorder(1,3), PMPIVAR%MPIConnect(i)%BGMBorder(2,3)
             !Counter = Counter + 1
             !IF (ANY(BGMSource(k,l,m,:).NE.0.0)) THEN
                !send_message(i)%content_log(Counter) = .TRUE.
                !SourceLength(i) = SourceLength(i) + 1
             !ELSE
                !send_message(i)%content_log(Counter) = .FALSE.
             !END IF
          !END DO
          !END DO
          !END DO
       !END IF
       !!--- same for periodic
       !IF(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor) THEN
          !DO n = 1, PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount
             !DO k = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,1),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,1)
             !DO l = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,2),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,2)
             !DO m = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,3),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,3)
                !Counter = Counter + 1
                !IF (ANY(BGMSource(k,l,m,:).NE.0.0)) THEN
                   !send_message(i)%content_log(Counter) = .TRUE.
                   !SourceLength(i) = SourceLength(i) + 1
                !ELSE
                   !send_message(i)%content_log(Counter) = .FALSE.
                !END IF
             !END DO
             !END DO
             !END DO
          !END DO
       !END IF
    !END DO
    !!--- communicate
    !messageCounterS = 0
    !DO i = 0,PMPIVAR%nProcs-1
       !IF ((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)) THEN
          !! MPI_ISEND true/false list for all border BGM points
          !messageCounterS = messageCounterS + 1
          !CALL MPI_ISEND(send_message(i)%content_log,MsgLength(i),MPI_LOGICAL,i,1,PMPIVAR%COMM, &
                         !send_request(messageCounterS), IERROR)
       !END IF
    !END DO
    !messageCounterR = 0
    !DO i = 0,PMPIVAR%nProcs-1
       !IF ((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)) THEN
          !! MPI_IRECV true/false list for all border BGM points from neighbor CPUs
          !messageCounterR = messageCounterR + 1
          !CALL MPI_IRECV(recv_message(i)%Content_log,MsgLength(i),MPI_LOGICAL,i,1,PMPIVAR%COMM, &
                         !recv_request(messageCounterR), IERROR)
       !END IF
    !END DO
    !! MPI_WAITALL for the non-blocking MPI-communication to be finished
    !IF (messageCounterS .GE. 1) THEN
       !CALL MPI_WAITALL(messageCounterS,send_request(1:messageCounterS),send_status_list(:,1:messageCounterS),IERROR)
    !END IF
    !IF (messageCounterR .GE. 1) THEN
       !CALL MPI_WAITALL(messageCounterR,recv_request(1:messageCounterR),recv_status_list(:,1:messageCounterR),IERROR)
    !END IF
   
    !!--- Assemble actual sources to send
     !DO i = 0,PMPIVAR%nProcs-1
       !IF (((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.&
            !(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)).AND.(SourceLength(i).GT.0)) THEN
          !ALLOCATE(send_message(i)%content(1:SourceLength(i)*4), STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
                !'ERROR in MPISourceExchangeBGM: cannot allocate send_message')
          !END IF
       !END IF
       !Counter = 0
       !Counter2 = 0
       !IF (PMPIVAR%MPIConnect(i)%isBGMNeighbor) THEN
          !DO k = PMPIVAR%MPIConnect(i)%BGMBorder(1,1), PMPIVAR%MPIConnect(i)%BGMBorder(2,1)
          !DO l = PMPIVAR%MPIConnect(i)%BGMBorder(1,2), PMPIVAR%MPIConnect(i)%BGMBorder(2,2)
          !DO m = PMPIVAR%MPIConnect(i)%BGMBorder(1,3), PMPIVAR%MPIConnect(i)%BGMBorder(2,3)
             !Counter = Counter + 1
             !IF (send_message(i)%content_log(Counter)) THEN
                !Counter2 = Counter2 + 1
                !DO n = 1,4
                   !send_message(i)%content((Counter2-1)*4 +n) = BGMSource(k,l,m,n)
                !END DO
             !END IF
          !END DO
          !END DO
          !END DO
       !END IF
       !IF (PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor) THEN
          !DO n = 1, PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount
             !DO k = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,1),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,1)
             !DO l = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,2),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,2)
             !DO m = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,3),&
                    !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,3)
                !Counter = Counter + 1
                !IF (send_message(i)%content_log(Counter)) THEN
                   !Counter2 = Counter2 + 1
                   !DO ppp = 1,4
                      !send_message(i)%content((Counter2-1)*4 +ppp) = BGMSource(k,l,m,ppp)
                   !END DO
                !END IF
             !END DO
             !END DO
             !END DO
          !END DO
       !END IF
    !END DO

    !!--- allocate actual source receive buffer
    !DO i = 0,PMPIVAR%nProcs-1
       !IF ((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)) THEN
          !Counter = 0
          !DO k = 1, MsgLength(i)
             !IF (recv_message(i)%Content_log(k)) THEN
                !Counter = Counter + 1
             !END IF
          !END DO
          !RecvLength(i) = Counter
          !IF (RecvLength(i).GT.0) THEN
             !ALLOCATE(recv_message(i)%content(1:Counter*4), STAT=allocStat)
             !IF (allocStat .NE. 0) THEN
                !CALL abort(__STAMP__, &
                  !'ERROR in MPISourceExchangeBGM: cannot allocate recv_message')
             !END IF
          !END IF
       !END IF
    !END DO
    !!--- communicate
    !messageCounterS = 0
    !DO i = 0,PMPIVAR%nProcs-1
       !IF (((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.&
            !(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)).AND.(SourceLength(i).GT.0)) THEN
          !! MPI_ISEND true/false list for all border BGM points
          !messageCounterS = messageCounterS + 1
          !CALL MPI_ISEND(send_message(i)%content,SourceLength(i)*4,myRealKind,i,1,PMPIVAR%COMM, &
                         !send_request(messageCounterS), IERROR)
       !END IF
    !END DO
    !messageCounterR = 0
    !DO i = 0,PMPIVAR%nProcs-1
       !IF (((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.&
            !(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)).AND.(RecvLength(i).GT.0)) THEN
          !! MPI_IRECV true/false list for all border BGM points from neighbor CPUs
          !messageCounterR = messageCounterR + 1
          !CALL MPI_IRECV(recv_message(i)%content,RecvLength(i)*4,myRealKind,i,1,PMPIVAR%COMM, &
                         !recv_request(messageCounterR), IERROR)
       !END IF
    !END DO
    !! MPI_WAITALL for the non-blocking MPI-communication to be finished
    !IF (messageCounterS .GE. 1) THEN
       !CALL MPI_WAITALL(messageCounterS,send_request(1:messageCounterS),send_status_list(:,1:messageCounterS),IERROR)
    !END IF
    !IF (messageCounterR .GE. 1) THEN
       !CALL MPI_WAITALL(messageCounterR,recv_request(1:messageCounterR),recv_status_list(:,1:messageCounterR),IERROR)
    !END IF
    !!--- Deallocate Send Message Buffers
    !DO i = 0,PMPIVAR%nProcs-1
       !IF ((PMPIVAR%MPIConnect(i)%isBGMNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor)) THEN
          !DEALLOCATE(send_message(i)%content_log, STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
                !'ERROR in MPISourceExchangeBGM: cannot deallocate send_message')
          !END IF
          !IF (SourceLength(i).GT.0) THEN
             !DEALLOCATE(send_message(i)%content, STAT=allocStat)
             !IF (allocStat .NE. 0) THEN
                !CALL abort(__STAMP__, &
                  !'ERROR in MPISourceExchangeBGM: cannot deallocate send_message')
             !END IF
          !END IF
       !END IF
    !END DO

    !!--- add selfperiodic sources, if any (needs to be done after send message is compiled and before
    !!---           received sources have been added!
    !IF ((GEO%nPeriodicVectors.GT.0).AND.(GEO%SelfPeriodic)) THEN
       !DO i = 1, GEO%nPeriodicVectors
          !DO k = BGMminX, BGMmaxX
             !k2 = k + GEO%PeriodicBGMVectors(1,i)
          !DO l = BGMminY, BGMmaxY
             !l2 = l + GEO%PeriodicBGMVectors(2,i)
          !DO m = BGMminZ, BGMmaxZ
             !m2 = m + GEO%PeriodicBGMVectors(3,i)
             !IF ((k2.GE.BGMminX).AND.(k2.LE.BGMmaxX)) THEN
             !IF ((l2.GE.BGMminY).AND.(l2.LE.BGMmaxY)) THEN
             !IF ((m2.GE.BGMminZ).AND.(m2.LE.BGMmaxZ)) THEN
                !BGMSource(k,l,m,:) = BGMSource(k,l,m,:) + BGMSource(k2,l2,m2,:)
                !BGMSource(k2,l2,m2,:) = BGMSource(k,l,m,:)
             !END IF
             !END IF
             !END IF
          !END DO
          !END DO
          !END DO
       !END DO
    !END IF

    !!--- Add Sources and Deallocate Receive Message Buffers
    !DO i = 0,PMPIVAR%nProcs-1
       !IF (RecvLength(i).GT.0) THEN
          !Counter = 0
          !Counter2 = 0
          !IF (PMPIVAR%MPIConnect(i)%isBGMNeighbor) THEN
             !DO k = PMPIVAR%MPIConnect(i)%BGMBorder(1,1), PMPIVAR%MPIConnect(i)%BGMBorder(2,1)
             !DO l = PMPIVAR%MPIConnect(i)%BGMBorder(1,2), PMPIVAR%MPIConnect(i)%BGMBorder(2,2)
             !DO m = PMPIVAR%MPIConnect(i)%BGMBorder(1,3), PMPIVAR%MPIConnect(i)%BGMBorder(2,3)
                !Counter = Counter + 1
                !IF(recv_message(i)%content_log(Counter))THEN
                   !Counter2 = Counter2 + 1
                   !DO n = 1,4
                     !BGMSource(k,l,m,n) = BGMSource(k,l,m,n) + recv_message(i)%content((Counter2-1)*4+n)
                   !END DO
                !END IF
             !END DO
             !END DO
             !END DO
          !END IF
          !IF (PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor) THEN
             !DO n = 1, PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount
                !DO k = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,1),&
                       !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,1)
                !DO l = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,2),&
                       !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,2)
                !DO m = PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(1,3),&
                       !PMPIVAR%MPIConnect(i)%Periodic(n)%BGMPeriodicBorder(2,3)
                   !Counter = Counter + 1
                   !IF(recv_message(i)%content_log(Counter))THEN
                      !Counter2 = Counter2 + 1
                      !DO ppp = 1,4
                         !BGMSource(k,l,m,ppp) = BGMSource(k,l,m,ppp) + recv_message(i)%content((Counter2-1)*4+ppp)
                      !END DO
                   !END IF
                !END DO
                !END DO
                !END DO
             !END DO
          !END IF
          !IF ((PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMNeighbor)) THEN
             !DEALLOCATE(recv_message(i)%content, STAT=allocStat)
             !IF (allocStat .NE. 0) THEN
                !CALL abort(__STAMP__, &
                  !'ERROR in MPISourceExchangeBGM: cannot deallocate recv_message')
             !END IF
          !END IF
       !END IF
       !IF ((PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor).OR.(PMPIVAR%MPIConnect(i)%isBGMNeighbor)) THEN
          !DEALLOCATE(recv_message(i)%content_log, STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
              !'ERROR in MPISourceExchangeBGM: cannot deallocate recv_message')
          !END IF
       !END IF
    !END DO
END SUBROUTINE MPISourceExchangeBGM

SUBROUTINE MPIBackgroundMeshInit()  
!============================================================================================================================
! initialize MPI background mesh
!============================================================================================================================
! use MODULES                                                                   
  !USE MOD_PICDepo_Vars
  !USE MOD_Particle_Vars    
  !USE MOD_Globals
  !USE MOD_part_MPI_Vars
!-----------------------------------------------------------------------------------------------------------------------------------
    IMPLICIT NONE                                                                                  
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
    !INTEGER                     :: i,k,m,n                                    
    !INTEGER                     :: localminmax(6), maxofmin, minofmax                              
    !INTEGER                     :: completeminmax(6*PMPIVAR%nProcs)                              
    !INTEGER                     :: allocStat, NeighCount                                                                 
    !INTEGER                     :: TempBorder(1:2,1:3)            
    !INTEGER                     :: Periodicminmax(6), coord, PeriodicVec(1:3)                   
    !INTEGER                     :: TempPeriBord(1:26,1:2,1:3)                                      
    !LOGICAL                     :: CHECKNEIGHBOR     
!-----------------------------------------------------------------------------------------------------------------------------------
  !Periodic Init stuff
 !IF(GEO%nPeriodicVectors.GT.0)THEN
    !Compute PeriodicBGMVectors (from PeriodicVectors and BGMdeltas)
   !ALLOCATE(GEO%PeriodicBGMVectors(1:3,1:GEO%nPeriodicVectors),STAT=allocStat)
   !IF (allocStat .NE. 0) THEN
     !CALL abort(__STAMP__, &
        !'ERROR in MPIBackgroundMeshInit: cannot allocate GEO%PeriodicBGMVectors!')
   !END IF
   !DO i = 1, GEO%nPeriodicVectors
     !GEO%PeriodicBGMVectors(1,i) = NINT(GEO%PeriodicVectors(1,i)/BGMdeltas(1))
     !IF(ABS(GEO%PeriodicVectors(1,i)/BGMdeltas(1)-REAL(GEO%PeriodicBGMVectors(1,i))).GT.1E-10)THEN
       !CALL abort(__STAMP__, &
        !'ERROR: Periodic Vector ist not multiple of background mesh delta')
     !END IF
     !GEO%PeriodicBGMVectors(2,i) = NINT(GEO%PeriodicVectors(2,i)/BGMdeltas(2))
     !IF(ABS(GEO%PeriodicVectors(2,i)/BGMdeltas(2)-REAL(GEO%PeriodicBGMVectors(2,i))).GT.1E-10)THEN
       !CALL abort(__STAMP__, &
        !'ERROR: Periodic Vector ist not multiple of background mesh delta')
     !END IF
     !GEO%PeriodicBGMVectors(3,i) = NINT(GEO%PeriodicVectors(3,i)/BGMdeltas(3))
     !IF(ABS(GEO%PeriodicVectors(3,i)/BGMdeltas(3)-REAL(GEO%PeriodicBGMVectors(3,i))).GT.1E-10)THEN
       !CALL abort(__STAMP__, &
        !'ERROR: Periodic Vector ist not multiple of background mesh delta')
     !END IF
   !END DO
    !Check whether process is periodic with itself
   !GEO%SelfPeriodic = .FALSE.
   !--- virtually move myself according to periodic vectors in order to find overlapping areas
   !--- 26 possibilities,
   !localminmax(1) = BGMminX
   !localminmax(2) = BGMminY
   !localminmax(3) = BGMminZ
   !localminmax(4) = BGMmaxX
   !localminmax(5) = BGMmaxY
   !localminmax(6) = BGMmaxZ
   !DO k = -1,1
     !DO m = -1,1
       !DO n = -1,1
         !PeriodicVec = k*GEO%PeriodicBGMVectors(:,1) + m*GEO%PeriodicBGMVectors(:,1) + n*GEO%PeriodicBGMVectors(:,1)
         !IF (ALL(PeriodicVec(:).EQ.0)) CYCLE
         !periodicminmax(1) = localminmax(1) + PeriodicVec(1)
         !periodicminmax(2) = localminmax(2) + PeriodicVec(2)
         !periodicminmax(3) = localminmax(3) + PeriodicVec(3)
         !periodicminmax(4) = localminmax(4) + PeriodicVec(1)
         !periodicminmax(5) = localminmax(5) + PeriodicVec(2)
         !periodicminmax(6) = localminmax(6) + PeriodicVec(3)
         !--- find overlap
         !DO coord = 1,3            x y z direction
           !maxofmin = MAX(periodicminmax(coord),localminmax(coord))
           !minofmax = MIN(periodicminmax(3+coord),localminmax(3+coord))
           !IF (maxofmin.LE.minofmax) GEO%SelfPeriodic = .TRUE.       overlapping
         !END DO
       !END DO
     !END DO
   !END DO
 !END IF

 !--- send and receive min max indices to and from all processes

    !--- enter local min max vector (xmin, ymin, zmin, xmax, ymax, zmax)
    !localminmax(1) = BGMminX
    !localminmax(2) = BGMminY
    !localminmax(3) = BGMminZ
    !localminmax(4) = BGMmaxX
    !localminmax(5) = BGMmaxY
    !localminmax(6) = BGMmaxZ
    !--- do allgather into complete min max vector
    !CALL MPI_ALLGATHER(localminmax,6,MPI_INTEGER,completeminmax,6,MPI_INTEGER,PMPIVAR%COMM,IERROR)
     !Allocate MPIConnect
    !SDEALLOCATE(PMPIVAR%MPIConnect)
    !ALLOCATE(PMPIVAR%MPIConnect(0:PMPIVAR%nProcs-1),STAT=allocStat)
    !IF (allocStat .NE. 0) THEN
      !CALL abort(__STAMP__, &
        !'ERROR in MPIBackgroundMeshInit: cannot allocate PMPIVAR%MPIConnect')
    !END IF

    !--- determine borders indices (=overlapping BGM mesh points) with each process
    !DO i = 0,PMPIVAR%nProcs-1
      !PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor = .FALSE.
      !PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount = 0
       !IF (i.EQ.PMPIVAR%iProc) THEN
          !PMPIVAR%MPIConnect(i)%isBGMNeighbor = .FALSE.
       !ELSE
          !PMPIVAR%MPIConnect(i)%isBGMNeighbor = .TRUE.
          !DO k = 1,3            x y z direction
             !maxofmin = MAX(localminmax(k),completeminmax((i*6)+k))
             !minofmax = MIN(localminmax(3+k),completeminmax((i*6)+3+k))
             !IF (maxofmin.LE.minofmax) THEN            overlapping
                !TempBorder(1,k) = maxofmin
                !TempBorder(2,k) = minofmax
             !ELSE
                !PMPIVAR%MPIConnect(i)%isBGMNeighbor = .FALSE.
             !END IF
          !END DO          
       !END IF
       !IF(PMPIVAR%MPIConnect(i)%isBGMNeighbor)THEN
          !SDEALLOCATE(PMPIVAR%MPIConnect(i)%BGMBorder)
          !ALLOCATE(PMPIVAR%MPIConnect(i)%BGMBorder(1:2,1:3),STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
             !CALL abort(__STAMP__, &
              !'ERROR in MPIBackgroundMeshInit: cannot allocate PMPIVAR%MPIConnect')
          !END IF
          !PMPIVAR%MPIConnect(i)%BGMBorder(1:2,1:3) = TempBorder(1:2,1:3)
       !END IF
    !END DO

    
    !--- determine border indices for periodic meshes  
    !IF (GEO%nPeriodicVectors.GT.0) THEN   
      !DO i = 0,PMPIVAR%nProcs-1
        !IF (i.EQ.PMPIVAR%iProc) THEN
          !PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor = .FALSE.
          !PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount = 0
        !ELSE
          !--- virtually move myself according to periodic vectors in order to find overlapping areas
          !--- 26 possibilities, processes need to work through them in opposite direction in order
          !--- to get matching areas.
          !--- Example for 2D:  I am process #3, I compare myself with #7
          !--- Periodic Vectors are p1 and p2.
          !--- I check p1, p2, p1+p2, p1-p2, -p1+p2, -p1-p2, -p2, -p1
          !--- #7 has to check -p1, -p2, -p1-p2, -p1+p2, p1-p2, p1+p1, p2, p1
          !--- This is done by doing 3 loops from -1 to 1 (for the higher process number)
          !--- or 1 to -1 (for the lower process number) and multiplying
          !--- these numbers to the periodic vectors
          !NeighCount = 0   -- counter: how often is the process my periodic neighbor?
          !PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor = .FALSE.
          !DO k = -SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i)
            !DO m = -SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i)
              !DO n = -SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i),SIGN(1,PMPIVAR%iProc-i)
                !IF ((k.EQ.0).AND.(m.EQ.0).AND.(n.EQ.0)) CYCLE this is not periodic and already done above
                !CHECKNEIGHBOR = .TRUE.
                !PeriodicVec = k*GEO%PeriodicBGMVectors(:,1)
                !IF (GEO%nPeriodicVectors.GT.1) THEN
                  !PeriodicVec = PeriodicVec + m*GEO%PeriodicBGMVectors(:,2)
                !END IF
                !IF (GEO%nPeriodicVectors.GT.2) THEN
                  !PeriodicVec = PeriodicVec + n*GEO%PeriodicBGMVectors(:,3)
                !END IF
                !periodicminmax(1) = localminmax(1) + PeriodicVec(1)
                !periodicminmax(2) = localminmax(2) + PeriodicVec(2)
                !periodicminmax(3) = localminmax(3) + PeriodicVec(3)
                !periodicminmax(4) = localminmax(4) + PeriodicVec(1)
                !periodicminmax(5) = localminmax(5) + PeriodicVec(2)
                !periodicminmax(6) = localminmax(6) + PeriodicVec(3)
                !--- find overlap
                !DO coord = 1,3            x y z direction
                  !maxofmin = MAX(periodicminmax(coord),completeminmax((i*6)+coord))
                  !minofmax = MIN(periodicminmax(3+coord),completeminmax((i*6)+3+coord))
                  !IF (maxofmin.LE.minofmax) THEN            overlapping
                    !TempBorder(1,coord) = maxofmin
                    !TempBorder(2,coord) = minofmax
                  !ELSE
                    !CHECKNEIGHBOR = .FALSE.
                  !END IF
                !END DO
                !IF(CHECKNEIGHBOR)THEN
                  !NeighCount = NeighCount + 1
                  !TempBorder(:,1) = TempBorder(:,1) - PeriodicVec(1)
                  !TempBorder(:,2) = TempBorder(:,2) - PeriodicVec(2)
                  !TempBorder(:,3) = TempBorder(:,3) - PeriodicVec(3)
                  !TempPeriBord(NeighCount,1:2,1:3) = TempBorder(1:2,1:3)
                  !PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor = .TRUE.
                !END IF
              !END DO
            !END DO
          !END DO
          !PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount = NeighCount
          !ALLOCATE(PMPIVAR%MPIConnect(i)%Periodic(1:PMPIVAR%MPIConnect(i)%BGMPeriodicBorderCount),STAT=allocStat)
          !IF (allocStat .NE. 0) THEN
            !CALL abort(__STAMP__,  &
              !'ERROR in MPIBackgroundMeshInit: cannot allocate PMPIVAR%MPIConnect')
          !END IF
          !DO k = 1,NeighCount
            !ALLOCATE(PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(1:2,1:3),STAT=allocStat)
            !IF (allocStat .NE. 0) THEN
              !CALL abort(__STAMP__, &
                !'ERROR in MPIBackgroundMeshInit: cannot allocate PMPIVAR%MPIConnect')
            !END IF
            !PMPIVAR%MPIConnect(i)%Periodic(k)%BGMPeriodicBorder(1:2,1:3) = TempPeriBord(k,1:2,1:3)
          !END DO
        !END IF
      !END DO
    !ELSE
      !--- initialize to FALSE for completely non-periodic cases
      !DO i = 0,PMPIVAR%nProcs-1
        !PMPIVAR%MPIConnect(i)%isBGMPeriodicNeighbor = .FALSE.
      !END DO
    !END IF
  !RETURN
END SUBROUTINE MPIBackgroundMeshInit
#endif /*MPI*/

SUBROUTINE DeBoor(PosInd, aux, coord, results, dir)       
!============================================================================================================================
! recursive function for evaluating a b-spline basis function
!============================================================================================================================
! use MODULES 
   USE MOD_PICDepo_Vars                                                          
!-----------------------------------------------------------------------------------------------------------------------------------
   IMPLICIT NONE                                                                                   
!-----------------------------------------------------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
   INTEGER, INTENT(IN)                          :: PosInd, dir  
   REAL, INTENT(IN)                             :: coord                                              
   REAL, INTENT(INOUT)                          :: aux(0:3), results                     
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES  
   INTEGER                          :: i,k,jL,jR                                                  
   REAL                              :: hlp1,hlp2                                                   
!-----------------------------------------------------------------------------------------------------------------------------------
    DO i = 0, 2
       DO k = 0, 2-i
          jL = PosInd - k
          jR = jL + 3 - i
          
          hlp1 = jR * BGMdeltas(dir) - coord
          hlp2 = coord - jL * BGMdeltas(dir)
         
          aux(k) = (hlp1 * aux(k+1) + hlp2 * aux(k)) / (hlp1+hlp2)
       ENDDO
    ENDDO
    results = aux(0)

    RETURN
END SUBROUTINE DeBoor


FUNCTION beta(z,w)  
!============================================================================================================================
! calculates the beta function
!============================================================================================================================
! use MODULES                                                                                               
   USE nr
!-----------------------------------------------------------------------------------------------------------------------------------
   IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
   REAL, INTENT(IN)                             :: w, z                                             
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
   REAL                                          :: beta
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES                                                    
!----------------------------------------------------------------------------------------------------------------------------------
   beta = exp(gammln(z)+gammln(w)-gammln(z+w))                                                                    
END FUNCTION beta 

END MODULE MOD_PICDepo
