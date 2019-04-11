!==================================================================================================================================
! Copyright (c) 2010 - 2018 Prof. Claus-Dieter Munz and Prof. Stefanos Fasoulas
!
! This file is part of PICLas (gitlab.com/piclas/piclas). PICLas is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3
! of the License, or (at your option) any later version.
!
! PICLas is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty
! of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License v3.0 for more details.
!
! You should have received a copy of the GNU General Public License along with PICLas. If not, see <http://www.gnu.org/licenses/>.
!==================================================================================================================================
#include "piclas.h"

MODULE MOD_Particle_Boundary_Sampling
!===================================================================================================================================
!! Determines how particles interact with a given boundary condition 
!===================================================================================================================================
! MODULES
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
PRIVATE
!-----------------------------------------------------------------------------------------------------------------------------------
! GLOBAL VARIABLES 
!-----------------------------------------------------------------------------------------------------------------------------------
! Private Part ---------------------------------------------------------------------------------------------------------------------

! Public Part ----------------------------------------------------------------------------------------------------------------------
INTERFACE InitParticleBoundarySampling
  MODULE PROCEDURE InitParticleBoundarySampling
END INTERFACE

INTERFACE FinalizeParticleBoundarySampling
  MODULE PROCEDURE FinalizeParticleBoundarySampling
END INTERFACE

INTERFACE WriteSurfSampleToHDF5
  MODULE PROCEDURE WriteSurfSampleToHDF5
END INTERFACE

#ifdef MPI
INTERFACE ExchangeSurfData
  MODULE PROCEDURE ExchangeSurfData
END INTERFACE

INTERFACE MapInnerSurfData
  MODULE PROCEDURE MapInnerSurfData
END INTERFACE
#endif /*MPI*/

PUBLIC::InitParticleBoundarySampling
PUBLIC::WriteSurfSampleToHDF5
PUBLIC::FinalizeParticleBoundarySampling
#ifdef MPI
PUBLIC::ExchangeSurfData
PUBLIC::MapInnerSurfData
#endif /*MPI*/
!===================================================================================================================================

CONTAINS

SUBROUTINE InitParticleBoundarySampling()
!===================================================================================================================================
! init of particle boundary sampling
! default: use for sampling same polynomial degree as NGeo
! 1) mark sides for sampling
! 2) build special MPI communicator
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Globals
USE MOD_ReadInTools
USE MOD_Preproc
USE MOD_Mesh_Vars               ,ONLY:NGeo,BC,nSides,nBCSides,nBCs,BoundaryName
USE MOD_ReadInTools             ,ONLY:GETINT
USE MOD_Particle_Boundary_Vars  ,ONLY:nSurfSample,dXiEQ_SurfSample,PartBound,XiEQ_SurfSample,SurfMesh,SampWall,nSurfBC,SurfBCName
USE MOD_Particle_Boundary_Vars  ,ONLY:SurfCOMM,CalcSurfCollis,AnalyzeSurfCollis,nPorousBC
USE MOD_Particle_Mesh_Vars      ,ONLY:nTotalSides,PartSideToElem,GEO
USE MOD_Particle_Vars           ,ONLY:nSpecies, PartSurfaceModel
USE MOD_Basis                   ,ONLY:LegendreGaussNodesAndWeights
USE MOD_Particle_Surfaces       ,ONLY:EvaluateBezierPolynomialAndGradient
USE MOD_Particle_Surfaces_Vars  ,ONLY:BezierControlPoints3D,BezierSampleN
USE MOD_Particle_Mesh_Vars      ,ONLY:PartBCSideList,PartElemToElemAndSide
USE MOD_Particle_Tracking_Vars  ,ONLY:DoRefMapping,TriaTracking
#ifdef MPI
USE MOD_Particle_MPI_Vars       ,ONLY:PartMPI
#else
USE MOD_Particle_Boundary_Vars  ,ONLY:offSetSurfSide
#endif /*MPI*/
USE MOD_PICDepo_Vars            ,ONLY:SFResampleAnalyzeSurfCollis
USE MOD_PICDepo_Vars            ,ONLY:LastAnalyzeSurfCollis
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                                :: p,q,iSide,SurfSideID,SideID,ElemID,LocSideID,iHaloSide
INTEGER                                :: iSample,jSample, iBC, iSpec
INTEGER                                :: TriNum, Node1, Node2 
REAL,DIMENSION(2,3)                    :: gradXiEta3D
REAL,ALLOCATABLE,DIMENSION(:)          :: Xi_NGeo,wGP_NGeo
REAL                                   :: XiOut(1:2),E,F,G,D,tmp1,area,tmpI2,tmpJ2
REAL                                   :: xNod, zNod, yNod, Vector1(3), Vector2(3), nx, ny, nz
REAL                                   :: nVal, SurfaceVal
CHARACTER(20)                          :: hilf, hilf2
CHARACTER(LEN=255),ALLOCATABLE         :: BCName(:)
INTEGER,ALLOCATABLE                    :: CalcSurfCollis_SpeciesRead(:) !help array for reading surface stuff
INTEGER,ALLOCATABLE                    :: ElemOfInnerBC(:),NBElemOfHalo(:)
LOGICAL,ALLOCATABLE                    :: IsSlaveSide(:)
!===================================================================================================================================
 
SWRITE(UNIT_stdOut,'(A)') ' INIT SURFACE SAMPLING ...'
WRITE(UNIT=hilf,FMT='(I0)') NGeo
nSurfSample = GETINT('DSMC-nSurfSample',TRIM(hilf))
! IF (NGeo.GT.nSurfSample) THEN
!   nSurfSample = NGeo
! END IF
IF (PartSurfaceModel.GT.0) THEN
  IF (nSurfSample.NE.BezierSampleN) THEN
  CALL abort(&
__STAMP__&
,'Error: nSurfSample not equal to BezierSampleN. Problem for Desorption + Surfflux')
  END IF
END IF
 
ALLOCATE(XiEQ_SurfSample(0:nSurfSample))

dXiEQ_SurfSample =2./REAL(nSurfSample)
DO q=0,nSurfSample
  XiEQ_SurfSample(q) = dXiEQ_SurfSample * REAL(q) - 1. 
END DO

! create boundary name mapping for surfaces SurfaceBC number mapping
nSurfBC = 0
ALLOCATE(BCName(1:nBCs))
DO iBC=1,nBCs
  BCName=''
END DO
DO iBC=1,nBCs
  IF (PartBound%MapToPartBC(iBC).EQ.-1) CYCLE !inner side (can be just in the name list from preproc although already sorted out)
  IF (PartBound%TargetBoundCond(PartBound%MapToPartBC(iBC)).EQ.PartBound%ReflectiveBC) THEN
  nSurfBC = nSurfBC + 1
  BCName(nSurfBC) = BoundaryName(iBC)
  END IF
END DO
IF (nSurfBC.GE.1) THEN
ALLOCATE(SurfBCName(1:nSurfBC))
  DO iBC=1,nSurfBC
    SurfBCName(iBC) = BCName(iBC)
  END DO
END IF
DEALLOCATE(BCName)
! get number of BC-Sides
ALLOCATE(SurfMesh%SideIDToSurfID(1:nTotalSides))
SurfMesh%SideIDToSurfID(1:nTotalSides)=-1
ALLOCATE(ElemOfInnerBC(1:nTotalSides))
ElemOfInnerBC(1:nTotalSides)=-1
ALLOCATE(NBElemOfHalo(1:nTotalSides))
NBElemOfHalo(1:nTotalSides)=-1
ALLOCATE(IsSlaveSide(1:nSides))
IsSlaveSide(1:nSides)= .FALSE.

! own BCsides
SurfMesh%nSides=0
SurfMesh%nBCSides=0
SurfMesh%nInnerSides=0
DO iSide=1,nBCSides
  IF(BC(iSide).EQ.0) CYCLE
  IF (PartBound%TargetBoundCond(PartBound%MapToPartBC(BC(iSide))).EQ.PartBound%ReflectiveBC) THEN
    SurfMesh%nSides = SurfMesh%nSides + 1
    SurfMesh%nBCSides = SurfMesh%nBCSides + 1
    SurfMesh%SideIDToSurfID(iSide)=SurfMesh%nSides
  END IF
END DO
! own inner BCsides (inner sides with refelctive PartBC)
! for clear assignment of innerBCSide between two procs Master/Slave definition is used
!   (1)     SlaveSides that are innerBCsides are tagged by IsSlaveSide(iSide)
!   (2)     SlaveSides is mapped to corresponding HaloSide
!           SampWall Informations of SlaveSides are added to SampWall Informations of corresponding HaloSide
DO iSide=nBCSides+1,nSides
  IF(BC(iSide).EQ.0) CYCLE
  IF (PartBound%TargetBoundCond(PartBound%MapToPartBC(BC(iSide))).EQ.PartBound%ReflectiveBC) THEN
    IF(PartSideToElem(S2E_ELEM_ID,iSide).NE.-1) THEN 
      SurfMesh%nSides = SurfMesh%nSides + 1
      SurfMesh%nInnerSides = SurfMesh%nInnerSides + 1  ! increment only for MasterSides
      SurfMesh%SideIDToSurfID(iSide)=SurfMesh%nSides
      IF(PartSideToElem(S2E_NB_ELEM_ID,iSide).EQ.-1) THEN
        ElemOfInnerBC(iSide)= PartSideToElem(S2E_ELEM_ID,iSide)
      END IF
    ELSE ! innerBCSides between two procs on SlaveSide
      IsSlaveSide(iSide) = .TRUE.   !(1)
      ElemOfInnerBC(iSide)= PartSideToElem(S2E_NB_ELEM_ID,iSide)
    END IF
  END IF
END DO

DO iSide=nBCSides+1,nSides
  IF(IsSlaveSide(iSide)) THEN
    SurfMesh%nSides = SurfMesh%nSides + 1
    SurfMesh%SideIDToSurfID(iSide)=SurfMesh%nSides
  END IF
END DO 

ALLOCATE(SurfMesh%innerBCSideToHaloMap(1:nTotalSides))
SurfMesh%innerBCSideToHaloMap(1:nTotalSides)=-1


! halo sides and Mapping for SlaveSide
SurfMesh%nTotalSides=SurfMesh%nSides
DO iHaloSide=nSides+1,nTotalSides
  IF(BC(iHaloSide).EQ.0) CYCLE
  IF (PartBound%TargetBoundCond(PartBound%MapToPartBC(BC(iHaloSide))).EQ.PartBound%ReflectiveBC) THEN
    SurfMesh%nTotalSides = SurfMesh%nTotalSides + 1
    SurfMesh%SideIDToSurfID(iHaloSide)=SurfMesh%nTotalSides
    IF (PartSideToElem(S2E_ELEM_ID,iHaloSide).NE.-1) THEN
      NBElemOfHalo(iHaloSide)= &
      PartElemToElemAndSide(1,PartSideToElem(S2E_LOC_SIDE_ID,iHaloSide),PartSideToElem(S2E_ELEM_ID,iHaloSide))
    ELSE
      NBElemOfHalo(iHaloSide)= &
      PartElemToElemAndSide(1,PartSideToElem(S2E_NB_LOC_SIDE_ID,iHaloSide),PartSideToElem(S2E_NB_ELEM_ID,iHaloSide))
    END IF
    DO iSide=nBCSides+1,nSides
      IF(IsSlaveSide(iSide)) THEN   !(2)
        IF (NBElemOfHalo(iHaloSide).EQ.ElemOfInnerBC(iSide)) THEN
          SurfMesh%innerBCSideToHaloMap(iSide)=iHaloSide
          IsSlaveSide(iSide) = .FALSE.
          EXIT
        END IF
      END IF
    END DO
  END IF
END DO

! sanity check
DO iSide=nBCSides+1,nSides
  IF(IsSlaveSide(iSide)) THEN
    CALL abort(&
__STAMP__&
,' Error in clear assignment of innerBCSide between two procs: No corresponding Halo-Side for innerBC SlaveSide', iSide)
  END IF
END DO 
! end sanity check

DEALLOCATE(ElemOfInnerBC)
DEALLOCATE(NBElemOfHalo)

ALLOCATE(SurfMesh%SurfIDToSideID(1:SurfMesh%nTotalSides))
SurfMesh%SurfIDToSideID(:) = -1
DO iSide = 1,nTotalSides
  IF (SurfMesh%SideIDToSurfID(iSide).LE.0) CYCLE
  SurfMesh%SurfIDToSideID(SurfMesh%SideIDToSurfID(iSide)) = iSide
END DO

SurfMesh%SurfOnProc=.FALSE.
!IF(SurfMesh%nSides.GT.0) 
IF(SurfMesh%nTotalSides.GT.0) SurfMesh%SurfOnProc=.TRUE.

#ifdef MPI
!CALL MPI_ALLREDUCE(SurfMesh%nSides,SurfMesh%nGlobalSides,1,MPI_INTEGER,MPI_SUM,PartMPI%COMM,iError)
CALL MPI_ALLREDUCE(SurfMesh%nBCSides+SurfMesh%nInnerSides,SurfMesh%nGlobalSides,1,MPI_INTEGER,MPI_SUM,PartMPI%COMM,iError)
#else
SurfMesh%nGlobalSides=SurfMesh%nBCSides+SurfMesh%nInnerSides
#endif


SWRITE(UNIT_stdOut,'(A,I8)') ' nGlobalSurfSides ', SurfMesh%nGlobalSides

SurfMesh%SampSize=9+3+nSpecies ! Energy + Force + nSpecies
#ifdef MPI
! split communitator
CALL InitSurfCommunicator()
IF(SurfMesh%SurfOnProc) THEN
  CALL GetHaloSurfMapping()
END IF
#else
SurfCOMM%MyRank=0
SurfCOMM%MPIRoot=.TRUE.
SurfCOMM%nProcs=1
SurfCOMM%MyOutputRank=0
SurfCOMM%MPIOutputRoot=.TRUE.
SurfCOMM%nOutputProcs = 1
SurfCOMM%nOutputProcs=1
! get correct offsets
OffSetSurfSide=0
#endif /*MPI*/

! Initialize surface collision sampling and analyze
CalcSurfCollis%OnlySwaps = GETLOGICAL('Particles-CalcSurfCollis_OnlySwaps','.FALSE.')
CalcSurfCollis%Only0Swaps = GETLOGICAL('Particles-CalcSurfCollis_Only0Swaps','.FALSE.')
CalcSurfCollis%Output = GETLOGICAL('Particles-CalcSurfCollis_Output','.FALSE.')
IF (CalcSurfCollis%Only0Swaps) CalcSurfCollis%OnlySwaps=.TRUE.
CalcSurfCollis%AnalyzeSurfCollis = GETLOGICAL('Particles-AnalyzeSurfCollis','.FALSE.')
AnalyzeSurfCollis%NumberOfBCs = 1 !initialize for ifs (BCs=0 means all)
ALLOCATE(AnalyzeSurfCollis%BCs(1))
AnalyzeSurfCollis%BCs = 0
IF (.NOT.CalcSurfCollis%AnalyzeSurfCollis .AND. SFResampleAnalyzeSurfCollis) THEN
  CALL abort(__STAMP__,&
    'ERROR: SFResampleAnalyzeSurfCollis was set without CalcSurfCollis%AnalyzeSurfCollis!')
END IF
IF (CalcSurfCollis%AnalyzeSurfCollis) THEN
  AnalyzeSurfCollis%maxPartNumber = GETINT('Particles-DSMC-maxSurfCollisNumber','0')
  AnalyzeSurfCollis%NumberOfBCs = GETINT('Particles-DSMC-NumberOfBCs','1')
  IF (AnalyzeSurfCollis%NumberOfBCs.EQ.1) THEN !already allocated
    AnalyzeSurfCollis%BCs = GETINTARRAY('Particles-DSMC-SurfCollisBC',1,'0') ! 0 means all...
  ELSE
    DEALLOCATE(AnalyzeSurfCollis%BCs)
    ALLOCATE(AnalyzeSurfCollis%BCs(1:AnalyzeSurfCollis%NumberOfBCs)) !dummy
    hilf2=''
    DO iBC=1,AnalyzeSurfCollis%NumberOfBCs !build default string: 0,0,0,...
      WRITE(UNIT=hilf,FMT='(I0)') 0
      hilf2=TRIM(hilf2)//TRIM(hilf)
      IF (iBC.NE.AnalyzeSurfCollis%NumberOfBCs) hilf2=TRIM(hilf2)//','
    END DO
    AnalyzeSurfCollis%BCs = GETINTARRAY('Particles-DSMC-SurfCollisBC',AnalyzeSurfCollis%NumberOfBCs,TRIM(hilf2))
  END IF
  ALLOCATE(AnalyzeSurfCollis%Data(1:AnalyzeSurfCollis%maxPartNumber,1:9))
  ALLOCATE(AnalyzeSurfCollis%Spec(1:AnalyzeSurfCollis%maxPartNumber))
  ALLOCATE(AnalyzeSurfCollis%BCid(1:AnalyzeSurfCollis%maxPartNumber))
  ALLOCATE(AnalyzeSurfCollis%Number(1:nSpecies+1))
  IF (LastAnalyzeSurfCollis%Restart) THEN
    CALL ReadAnalyzeSurfCollisToHDF5()
  END IF
  !ALLOCATE(AnalyzeSurfCollis%Rate(1:nSpecies+1))
  AnalyzeSurfCollis%Data=0.
  AnalyzeSurfCollis%Spec=0
  AnalyzeSurfCollis%BCid=0
  AnalyzeSurfCollis%Number=0
  !AnalyzeSurfCollis%Rate=0.
END IF
! Species-dependent calculations
ALLOCATE(CalcSurfCollis%SpeciesFlags(1:nSpecies))
CalcSurfCollis%NbrOfSpecies = GETINT('Particles-CalcSurfCollis_NbrOfSpecies','0')
IF ( (CalcSurfCollis%NbrOfSpecies.GT.0) .AND. (CalcSurfCollis%NbrOfSpecies.LE.nSpecies) ) THEN
  ALLOCATE(CalcSurfCollis_SpeciesRead(1:CalcSurfCollis%NbrOfSpecies))
  hilf2=''
  DO iSpec=1,CalcSurfCollis%NbrOfSpecies !build default string: 1 - CSC_NoS
    WRITE(UNIT=hilf,FMT='(I0)') iSpec
    hilf2=TRIM(hilf2)//TRIM(hilf)
    IF (ispec.NE.CalcSurfCollis%NbrOfSpecies) hilf2=TRIM(hilf2)//','
  END DO
  CalcSurfCollis_SpeciesRead = GETINTARRAY('Particles-CalcSurfCollis_Species',CalcSurfCollis%NbrOfSpecies,TRIM(hilf2))
  CalcSurfCollis%SpeciesFlags(:)=.FALSE.
  DO iSpec=1,CalcSurfCollis%NbrOfSpecies
    CalcSurfCollis%SpeciesFlags(CalcSurfCollis_SpeciesRead(ispec))=.TRUE.
  END DO
  DEALLOCATE(CalcSurfCollis_SpeciesRead)
ELSE IF (CalcSurfCollis%NbrOfSpecies.EQ.0) THEN !default
  CalcSurfCollis%SpeciesFlags(:)=.TRUE.
ELSE
  CALL abort(&
  __STAMP__&
  ,'Error in Particles-CalcSurfCollis_NbrOfSpecies!')
END IF

IF(.NOT.SurfMesh%SurfOnProc) RETURN


! allocate everything
ALLOCATE(SampWall(1:SurfMesh%nTotalSides))


DO iSide=1,SurfMesh%nTotalSides ! caution: iSurfSideID
  ALLOCATE(SampWall(iSide)%State(1:SurfMesh%SampSize,1:nSurfSample,1:nSurfSample))
  SampWall(iSide)%State=0.
  IF(nPorousBC.GT.0) SampWall(iSide)%PumpCapacity = 0.
  !ALLOCATE(SampWall(iSide)%Energy(1:9,0:nSurfSample,0:nSurfSample)         &
  !        ,SampWall(iSide)%Force(1:9,0:nSurfSample,0:nSurfSample)          &
  !        ,SampWall(iSide)%Counter(1:nSpecies,0:nSurfSample,0:nSurfSample) )
  ! nullify
  !SampWall(iSide)%Energy(1:9,0:nSurfSample,0:nSurfSample)         = 0.
  !SampWall(iSide)%Force(1:9,0:nSurfSample,0:nSurfSample)          = 0.
  !SampWall(iSide)%Counter(1:nSpecies,0:nSurfSample,0:nSurfSample) = 0.
END DO

ALLOCATE(SurfMesh%SurfaceArea(1:nSurfSample,1:nSurfSample,1:SurfMesh%nTotalSides)) 
SurfMesh%SurfaceArea=0.

ALLOCATE(Xi_NGeo( 0:NGeo)  &
        ,wGP_NGeo(0:NGeo) )
CALL LegendreGaussNodesAndWeights(NGeo,Xi_NGeo,wGP_NGeo)
! compute area of sub-faces
tmp1=dXiEQ_SurfSample/2.0 !(b-a)/2
DO iSide=1,nTotalSides
  SurfSideID=SurfMesh%SideIDToSurfID(iSide)
  IF(SurfSideID.EQ.-1) CYCLE
  IF(DoRefMapping)THEN
    SideID=PartBCSideList(iSide)
  ELSE
    SideID=iSide
  END IF
  IF (TriaTracking) THEN
    ElemID = PartSideToElem(S2E_ELEM_ID,iSide)
    LocSideID = PartSideToElem(S2E_LOC_SIDE_ID,iSide)
    IF (ElemID.EQ.-1) THEN
        ElemID=PartSideToElem(S2E_NB_ELEM_ID,iSide)
        LocSideID = PartSideToElem(S2E_NB_LOC_SIDE_ID,iSide)
    END IF
    SurfaceVal = 0.
    xNod = GEO%NodeCoords(1,GEO%ElemSideNodeID(1,LocSideID,ElemID))
    yNod = GEO%NodeCoords(2,GEO%ElemSideNodeID(1,LocSideID,ElemID))
    zNod = GEO%NodeCoords(3,GEO%ElemSideNodeID(1,LocSideID,ElemID))

    DO TriNum = 1,2
      Node1 = TriNum+1     ! normal = cross product of 1-2 and 1-3 for first triangle
      Node2 = TriNum+2     !          and 1-3 and 1-4 for second triangle
      Vector1(1) = GEO%NodeCoords(1,GEO%ElemSideNodeID(Node1,LocSideID,ElemID)) - xNod
      Vector1(2) = GEO%NodeCoords(2,GEO%ElemSideNodeID(Node1,LocSideID,ElemID)) - yNod
      Vector1(3) = GEO%NodeCoords(3,GEO%ElemSideNodeID(Node1,LocSideID,ElemID)) - zNod
      Vector2(1) = GEO%NodeCoords(1,GEO%ElemSideNodeID(Node2,LocSideID,ElemID)) - xNod
      Vector2(2) = GEO%NodeCoords(2,GEO%ElemSideNodeID(Node2,LocSideID,ElemID)) - yNod
      Vector2(3) = GEO%NodeCoords(3,GEO%ElemSideNodeID(Node2,LocSideID,ElemID)) - zNod
      nx = - Vector1(2) * Vector2(3) + Vector1(3) * Vector2(2) !NV (inwards)
      ny = - Vector1(3) * Vector2(1) + Vector1(1) * Vector2(3)
      nz = - Vector1(1) * Vector2(2) + Vector1(2) * Vector2(1)
      nVal = SQRT(nx*nx + ny*ny + nz*nz)
      SurfaceVal = SurfaceVal + nVal/2.
    END DO
    SurfMesh%SurfaceArea(1,1,SurfSideID) = SurfaceVal
  ELSE
    ! call here stephens algorithm to compute area 
    DO jSample=1,nSurfSample
      DO iSample=1,nSurfSample
        area=0.
        tmpI2=(XiEQ_SurfSample(iSample-1)+XiEQ_SurfSample(iSample))/2. ! (a+b)/2
        tmpJ2=(XiEQ_SurfSample(jSample-1)+XiEQ_SurfSample(jSample))/2. ! (a+b)/2
        DO q=0,NGeo
          DO p=0,NGeo
            XiOut(1)=tmp1*Xi_NGeo(p)+tmpI2
            XiOut(2)=tmp1*Xi_NGeo(q)+tmpJ2
            CALL EvaluateBezierPolynomialAndGradient(XiOut,NGeo,3,BezierControlPoints3D(1:3,0:NGeo,0:NGeo,SideID) &
                                                    ,Gradient=gradXiEta3D)
            ! calculate first fundamental form
            E=DOT_PRODUCT(gradXiEta3D(1,1:3),gradXiEta3D(1,1:3))
            F=DOT_PRODUCT(gradXiEta3D(1,1:3),gradXiEta3D(2,1:3))
            G=DOT_PRODUCT(gradXiEta3D(2,1:3),gradXiEta3D(2,1:3))
            D=SQRT(E*G-F*F)
            area = area+tmp1*tmp1*D*wGP_NGeo(p)*wGP_NGeo(q)      
          END DO
        END DO
        SurfMesh%SurfaceArea(iSample,jSample,SurfSideID) = area 
      END DO ! iSample=1,nSurfSample
    END DO ! jSample=1,nSurfSample
  END IF
END DO ! iSide=1,nTotalSides

! get the full area of the BC's of all faces
Area=0.
DO iSide=1,nSides
  SurfSideID=SurfMesh%SideIDToSurfID(iSide)
  IF(SurfSideID.EQ.-1) CYCLE
  Area = Area + SUM(SurfMesh%SurfaceArea(:,:,SurfSideID))
END DO ! iSide=1,nTotalSides

#ifdef MPI
CALL MPI_ALLREDUCE(MPI_IN_PLACE,Area,1,MPI_DOUBLE_PRECISION,MPI_SUM,SurfCOMM%COMM,iError)
#endif /*MPI*/

SWRITE(UNIT_stdOut,'(A,ES25.14E3)') ' Surface-Area: ', Area

DEALLOCATE(Xi_NGeo,wGP_NGeo)

SWRITE(UNIT_stdOut,'(A)') ' ... DONE.'

END SUBROUTINE InitParticleBoundarySampling

#ifdef MPI
SUBROUTINE InitSurfCommunicator()
!===================================================================================================================================
! Creates two new subcommunicators. 
! SurfCOMM%COMM contains all MPI-Ranks which have reflective boundary faces in their halo-region and process which have reflective
! boundary faces in their origin region. This communicator is used to communicate the wall-sampled values of halo-faces to the
! origin face
! SurfCOMM%OutputCOMM is another subset. This communicator contains only the processes with origin surfaces. It is used to perform
! collective writes of the surf-sampled values.
! Sets also used for communication of adsorption variables
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Particle_Boundary_Vars   ,ONLY:SurfMesh
USE MOD_Particle_Boundary_Vars   ,ONLY:SurfCOMM
USE MOD_Particle_MPI_Vars        ,ONLY:PartMPI
USE MOD_Particle_Boundary_Vars   ,ONLY:OffSetSurfSideMPI,OffSetSurfSide,OffSetInnerSurfSideMPI,OffSetInnerSurfSide
! IMPLICIT VARIABLE HANDLING
 IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                   :: color,iProc
INTEGER                   :: noSurfrank,Surfrank
LOGICAL                   :: hasSurf
INTEGER,ALLOCATABLE       :: countSurfSideMPI(:),countInnerSurfSideMPI(:)
LOGICAL                   :: OutputOnProc
!===================================================================================================================================
color=MPI_UNDEFINED
IF(SurfMesh%SurfOnProc) color=2
! THEN
! color=2
! ELSE
! color=1
! END IF
! create ranks for RP communicator
IF(PartMPI%MPIRoot) THEN
  Surfrank=-1
  noSurfrank=-1
  SurfCOMM%Myrank=0
  IF(SurfMesh%SurfOnProc) THEN
    Surfrank=0
  ELSE 
    noSurfrank=0
  END IF
  DO iProc=1,nProcessors-1
    CALL MPI_RECV(hasSurf,1,MPI_LOGICAL,iProc,0,MPI_COMM_WORLD,MPIstatus,iError)
    IF(hasSurf) THEN
      SurfRank=SurfRank+1
      CALL MPI_SEND(SurfRank,1,MPI_INTEGER,iProc,0,MPI_COMM_WORLD,iError)
    ELSE
      noSurfRank=noSurfRank+1
      CALL MPI_SEND(noSurfRank,1,MPI_INTEGER,iProc,0,MPI_COMM_WORLD,iError)
    END IF
  END DO
ELSE
  CALL MPI_SEND(SurfMesh%SurfOnProc,1,MPI_LOGICAL,0,0,MPI_COMM_WORLD,iError)
  CALL MPI_RECV(SurfCOMM%MyRank,1,MPI_INTEGER,0,0,MPI_COMM_WORLD,MPIstatus,iError)
END IF

! create new SurfMesh communicator for SurfMesh communication
CALL MPI_COMM_SPLIT(PartMPI%COMM, color, SurfCOMM%MyRank, SurfCOMM%COMM,iError)
IF(SurfMesh%SurfOnPRoc) THEN
  CALL MPI_COMM_SIZE(SurfCOMM%COMM, SurfCOMM%nProcs,iError)
ELSE
  SurfCOMM%nProcs = 0
END IF
SurfCOMM%MPIRoot=.FALSE.
IF(SurfCOMM%MyRank.EQ.0 .AND. SurfMesh%SurfOnProc) THEN
  SurfCOMM%MPIRoot=.TRUE.
!   WRITE(UNIT_stdout,'(A18,I5,A6)') 'SURF COMM:        ',SurfCOMM%nProcs,' procs'
END IF

! now, create output communicator
OutputOnProc=.FALSE.
color=MPI_UNDEFINED
IF(SurfMesh%nSides.GT.0) THEN
  OutputOnProc=.TRUE.
  color=4
END IF

IF(PartMPI%MPIRoot) THEN
  Surfrank=-1
  noSurfrank=-1
  SurfCOMM%MyOutputRank=0
  IF(SurfMesh%nSides.GT.0) THEN
    Surfrank=0
  ELSE 
    noSurfrank=0
  END IF
  DO iProc=1,nProcessors-1
    CALL MPI_RECV(hasSurf,1,MPI_LOGICAL,iProc,0,MPI_COMM_WORLD,MPIstatus,iError)
    IF(hasSurf) THEN
      SurfRank=SurfRank+1
      CALL MPI_SEND(SurfRank,1,MPI_INTEGER,iProc,0,MPI_COMM_WORLD,iError)
    ELSE
      noSurfRank=noSurfRank+1
      CALL MPI_SEND(noSurfRank,1,MPI_INTEGER,iProc,0,MPI_COMM_WORLD,iError)
    END IF
  END DO
ELSE
  CALL MPI_SEND(OutputOnProc,1,MPI_LOGICAL,0,0,MPI_COMM_WORLD,iError)
  CALL MPI_RECV(SurfCOMM%MyOutputRank,1,MPI_INTEGER,0,0,MPI_COMM_WORLD,MPIstatus,iError)
END IF

! create new SurfMesh Output-communicator 
CALL MPI_COMM_SPLIT(PartMPI%COMM, color, SurfCOMM%MyOutputRank, SurfCOMM%OutputCOMM,iError)
IF(OutputOnPRoc)THEN
  CALL MPI_COMM_SIZE(SurfCOMM%OutputCOMM, SurfCOMM%nOutputProcs,iError)
ELSE
  SurfCOMM%nOutputProcs = 0
END IF
SurfCOMM%MPIOutputRoot=.FALSE.
IF(SurfCOMM%MyOutputRank.EQ.0 .AND. OutputOnProc) THEN
  SurfCOMM%MPIOutputRoot=.TRUE.
!   WRITE(UNIT_stdout,'(A18,I5,A6)') 'SURF OUTPUT-COMM: ',SurfCOMM%nOutputProcs,' procs'
END IF

IF(SurfMesh%nSides.EQ.0) RETURN

! get correct offsets
ALLOCATE(offsetSurfSideMPI(0:SurfCOMM%nOutputProcs))
offsetSurfSideMPI=0
ALLOCATE(countSurfSideMPI(0:SurfCOMM%nOutputProcs-1))
countSurfSideMPI=0

CALL MPI_GATHER(SurfMesh%nBCSides+SurfMesh%nInnerSides,1,MPI_INTEGER,countSurfSideMPI,1,MPI_INTEGER,0,SurfCOMM%OutputCOMM,iError)

! new offsets due to InnerSurfSides
ALLOCATE(offsetInnerSurfSideMPI(0:SurfCOMM%nOutputProcs))
offsetInnerSurfSideMPI=0
ALLOCATE(countInnerSurfSideMPI(0:SurfCOMM%nOutputProcs-1))
countInnerSurfSideMPI=0

CALL MPI_GATHER(SurfMesh%nInnerSides,1,MPI_INTEGER,countInnerSurfSideMPI,1,MPI_INTEGER,0,SurfCOMM%OutputCOMM,iError)

IF (SurfCOMM%MPIOutputRoot) THEN
  DO iProc=1,SurfCOMM%nOutputProcs-1
    offsetSurfSideMPI(iProc)=SUM(countSurfSideMPI(0:iProc-1))-SUM(countInnerSurfSideMPI(0:iProc-1))
    offsetInnerSurfSideMPI(iProc)=SUM(countInnerSurfSideMPI(0:iProc-1))
  END DO
  offsetSurfSideMPI(SurfCOMM%nOutputProcs)=SUM(countSurfSideMPI(:))-SUM(countInnerSurfSideMPI(:))
  offsetInnerSurfSideMPI(SurfCOMM%nOutputProcs)=SUM(countInnerSurfSideMPI(:))
  ! add BC offset to InnerSurfSide offset
  offsetInnerSurfSideMPI(0:SurfCOMM%nOutputProcs) = &
  offsetInnerSurfSideMPI(0:SurfCOMM%nOutputProcs) + offsetSurfSideMPI(SurfCOMM%nOutputProcs)
END IF

CALL MPI_BCAST (offsetSurfSideMPI,size(offsetSurfSideMPI),MPI_INTEGER,0,SurfCOMM%OutputCOMM,iError)
offsetSurfSide=offsetSurfSideMPI(SurfCOMM%MyOutputRank)
CALL MPI_BCAST (offsetInnerSurfSideMPI,size(offsetInnerSurfSideMPI),MPI_INTEGER,0,SurfCOMM%OutputCOMM,iError)
offsetInnerSurfSide=offsetInnerSurfSideMPI(SurfCOMM%MyOutputRank)

END SUBROUTINE InitSurfCommunicator


SUBROUTINE GetHaloSurfMapping()
!===================================================================================================================================
! build all missing stuff for surface-sampling communicator, like
! offSetMPI
! MPI-neighbor list
! PartHaloSideToProc
! only receiving process knows to which local side the sending information is going, the sending process does not know the final 
! sideid 
! if only a processes has to send his data to another, the whole structure is build, but not filled. only if the nsidesrecv,send>0
! communication is performed
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Globals
USE MOD_Preproc
USE MOD_Mesh_Vars                   ,ONLY:nSides,nBCSides
USE MOD_Particle_Boundary_Vars      ,ONLY:SurfMesh,SurfComm,nSurfSample, nPorousBC, nPorousBCVars 
USE MOD_Particle_MPI_Vars           ,ONLY:PartHaloSideToProc,PartHaloElemToProc,SurfSendBuf,SurfRecvBuf,SurfExchange
USE MOD_Particle_Mesh_Vars          ,ONLY:nTotalSides,PartSideToElem,PartElemToSide
USE MOD_Particle_MPI_Vars           ,ONLY:PorousBCSendBuf,PorousBCRecvBuf
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
LOGICAL                           :: isMPINeighbor(0:SurfCOMM%nProcs-1)
LOGICAL                           :: RecvMPINeighbor(0:SurfCOMM%nProcs-1)
INTEGER                           :: nDOF,ALLOCSTAT,SideID, TargetProc, TargetElem
INTEGER                           :: iProc, GlobalProcID,iSide,ElemID,SurfSideID,LocalProcID,iSendSide,iRecvSide,iPos
INTEGER,ALLOCATABLE               :: recv_status_list(:,:) 
INTEGER                           :: RecvRequest(0:SurfCOMM%nProcs-1),SendRequest(0:SurfCOMM%nProcs-1)
INTEGER                           :: SurfToGlobal(0:SurfCOMM%nProcs-1)
INTEGER                           :: NativeElemID, NativeLocSideID, LocSideID
!===================================================================================================================================

nDOF=(nSurfSample)*(nSurfSample)

! get mapping from local rank to global rank...
CALL MPI_ALLGATHER(MyRank,1, MPI_INTEGER, SurfToGlobal(0:SurfCOMM%nProcs-1), 1, MPI_INTEGER, SurfCOMM%COMM, IERROR)

! get list of mpi surf-comm neighbors in halo-region
isMPINeighbor=.FALSE.
IF(SurfMesh%nTotalSides.GT.SurfMesh%nSides)THEN
  ! PartHaloSideToProc has the mapping from the local sideid to the corresponding 
  ! element-id, localsideid, native-proc-id and local-proc-id
  ! caution: 
  ! native-proc-id is id in global list || PartMPI%COMM
  ! local-proc-id is the nth neighbor in SurfCOMM%COMM
  ! caution2:
  !  this mapping is done only for reflective bcs, thus, each open side or non-reflective side 
  !  points to -1
  ! get all MPI-neighbors to communicate with
  DO iProc=0,SurfCOMM%nProcs-1
    IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
    GlobalProcID=SurfToGlobal(iProc)
    DO iSide=nSides+1,nTotalSides
      SurfSideID=SurfMesh%SideIDToSurfID(iSide)
      IF(SurfSideID.EQ.-1) CYCLE
      ! get elemid
      ElemID=PartSideToElem(S2E_ELEM_ID,iSide)
      IF (ElemID.EQ.-1) THEN
        ElemID=PartSideToElem(S2E_NB_ELEM_ID,iSide)
      END IF
      TargetProc=PartHaloElemToProc(NATIVE_PROC_ID,ElemID)
      IF(ElemID.LE.PP_nElems)THEN
        CALL abort(&
__STAMP__&
,' Error in PartSideToElem. Halo-Side cannot be connected to local element', ElemID  )
      END IF
      IF(GlobalProcID.EQ.TargetProc)THEN
        IF(.NOT.isMPINeighbor(iProc))THEN
          isMPINeighbor(iProc)=.TRUE.
        END IF
      END IF
    END DO ! iSide=nSides+1,nTotalSides
  END DO ! iProc = 0, SurfCOMM%nProcs-1
END IF

! Make sure SurfCOMM%MPINeighbor is consistent
! 1) communication of found is neighbor
ALLOCATE(RECV_STATUS_LIST(1:MPI_STATUS_SIZE,0:SurfCOMM%nProcs-1))
! receive and send connection information
DO iProc=0,SurfCOMM%nProcs-1
  IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
  CALL MPI_IRECV( RecvMPINeighbor(iProc)                    &
                , 1                                         &
                , MPI_LOGICAL                               &
                , iProc                                     &
                , 1001                                      &
                , SurfCOMM%COMM                             &
                , RecvRequest(iProc)                        &  
                , IERROR )
END DO ! iProc
DO iProc=0,SurfCOMM%nProcs-1
  IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
  CALL MPI_ISEND( isMPINeighbor(iProc)                      &
                , 1                                         &
                , MPI_LOGICAL                               &
                , iProc                                     &
                , 1001                                      &
                , SurfCOMM%COMM                             &
                , SendRequest(iProc)                        & 
                , IERROR )
  IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
    __STAMP__&
    ,' MPI Communication error', IERROR)
END DO ! iProc

! finish communication
DO iProc=0,SurfCOMM%nProcs-1
  IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
  CALL MPI_WAIT(SendRequest(iProc),MPIStatus,IERROR)
  IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
    __STAMP__&
    ,' MPI Communication error', IERROR)
  CALL MPI_WAIT(RecvRequest(iProc),recv_status_list(:,iProc),IERROR)
  IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
    __STAMP__&
    ,' MPI Communication error', IERROR)
END DO ! iProc
DEALLOCATE(RECV_STATUS_LIST)

! 2) finalize MPI consistency check.
DO iProc=0,SurfCOMM%nProcs-1
  IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
  IF (RecvMPINeighbor(iProc).NEQV.isMPINeighbor(iProc)) THEN
    IF(.NOT.isMPINeighbor(iProc))THEN
      isMPINeighbor(iProc)=.TRUE.
      ! it is a debug output
      !IPWRITE(UNIT_stdOut,*) ' Found missing mpi-neighbor'
    END IF
  END IF
END DO ! iProc

! build the mapping
SurfCOMM%nMPINeighbors=0
IF(ANY(IsMPINeighbor))THEN
  ! PartHaloSideToProc has the mapping from the local sideid to the corresponding 
  ! element-id, localsideid, native-proc-id and local-proc-id
  ! caution: 
  ! native-proc-id is id in global list || PartMPI%COMM
  ! local-proc-id is the nth neighbor in SurfCOMM%COMM
  ! caution2:
  !  this mapping is done only for reflective bcs, thus, each open side or non-reflective side 
  !  points to -1
  IF(SurfMesh%nTotalSides.GT.SurfMesh%nSides)THEN
    ALLOCATE(PartHaloSideToProc(1:4,nSides+1:nTotalSides))
    PartHaloSideToProc=-1
    ! get all MPI-neighbors to communicate with
    DO iProc=0,SurfCOMM%nProcs-1
      IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
      IF(isMPINeighbor(iProc))THEN
        SurfCOMM%nMPINeighbors=SurfCOMM%nMPINeighbors+1
      ELSE
        CYCLE
      END IF
      GlobalProcID=SurfToGlobal(iProc)
      DO iSide=nSides+1,nTotalSides
        SurfSideID=SurfMesh%SideIDToSurfID(iSide)
        IF(SurfSideID.EQ.-1) CYCLE
        ! get elemid
        ElemID=PartSideToElem(S2E_ELEM_ID,iSide)
        IF (ElemID.EQ.-1) THEN
          ElemID=PartSideToElem(S2E_NB_ELEM_ID,iSide)
        END IF
        TargetProc=PartHaloElemToProc(NATIVE_PROC_ID,ElemID)
        IF(ElemID.LE.PP_nElems)THEN
        CALL abort(&
__STAMP__&
,' Error in PartSideToElem. Halo-Side cannot be connected to local element', ElemID  )
        END IF
        IF(GlobalProcID.EQ.TargetProc)THEN
          ! caution: 
          ! native-proc-id is id in global list || PartMPI%COMM
          ! local-proc-id is the nth neighbor in SurfCOMM%COMM
          PartHaloSideToProc(NATIVE_PROC_ID,iSide)=GlobalProcID
          PartHaloSideToProc(LOCAL_PROC_ID ,iSide)=SurfCOMM%nMPINeighbors
        END IF
      END DO ! iSide=nSides+1,nTotalSides
    END DO ! iProc = 0, SurfCOMM%nProcs-1
  ELSE
    ! process receives only surface data from other processes, but does not send data.
    DO iProc=0,SurfCOMM%nProcs-1
      IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
      IF(isMPINeighbor(iProc)) SurfCOMM%nMPINeighbors=SurfCOMM%nMPINeighbors+1
    END DO ! iProc = 0, SurfCOMM%nProcs-1
  END IF
END IF
! build SurfMesh exchange information
! next, allocate SurfCOMM%MPINeighbor
ALLOCATE(SurfCOMM%MPINeighbor(1:SurfCOMM%nMPINeighbors))
! set native proc-id of each SurfCOMM-MPI-Neighbor
LocalProcID=0
DO iProc = 0,SurfCOMM%nProcs-1
  IF(iProc.EQ.SurfCOMM%MyRank) CYCLE
  IF(isMPINeighbor(iProc))THEN
    LocalProcID=LocalProcID+1
    ! map from local proc id to global
    SurfCOMM%MPINeighbor(LocalProcID)%NativeProcID=iProc !PartMPI%MPINeighbor(iProc)
  END IF
END DO ! iProc=1,PartMPI%nMPINeighbors

! array how many data has to be communicated
! number of Sides
ALLOCATE(SurfExchange%nSidesSend(1:SurfCOMM%nMPINeighbors) &
        ,SurfExchange%nSidesRecv(1:SurfCOMM%nMPINeighbors) &
        ,SurfExchange%SendRequest(SurfCOMM%nMPINeighbors)  &
        ,SurfExchange%RecvRequest(SurfCOMM%nMPINeighbors)  )

SurfExchange%nSidesSend=0
SurfExchange%nSidesRecv=0
! loop over all neighbors  
DO iProc=1,SurfCOMM%nMPINeighbors
  ! proc-id in SurfCOMM%nProcs
  DO iSide=nSides+1,nTotalSides
    SurfSideID=SurfMesh%SideIDToSurfID(iSide)
    IF(SurfSideID.EQ.-1) CYCLE
    IF(iProc.EQ.PartHaloSideToProc(LOCAL_PROC_ID,iSide))THEN
      SurfExchange%nSidesSend(iProc)=SurfExchange%nSidesSend(iProc)+1
      PartHaloSideToProc(LOCAL_SEND_ID,iSide) =SurfExchange%nSidesSend(iProc)
    END IF
  END DO ! iSide=nSides+1,nTotalSides
END DO ! iProc=1,SurfCOMM%nMPINeighbors


! open receive number of send particles
ALLOCATE(RECV_STATUS_LIST(1:MPI_STATUS_SIZE,1:SurfCOMM%nMPINeighbors))
DO iProc=1,SurfCOMM%nMPINeighbors
  CALL MPI_IRECV( SurfExchange%nSidesRecv(iProc)            &
                , 1                                         &
                , MPI_INTEGER                               &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID  &
                , 1001                                      &
                , SurfCOMM%COMM                             &
                , SurfExchange%RecvRequest(iProc)           & 
                , IERROR )
END DO ! iProc

DO iProc=1,SurfCOMM%nMPINeighbors
  ALLOCATE(SurfCOMM%MPINeighbor(iProc)%SendList(SurfExchange%nSidesSend(iProc)))
  SurfCOMM%MPINeighbor(iProc)%SendList=0
  CALL MPI_ISEND( SurfExchange%nSidesSend(iProc)           &
                , 1                                        &
                , MPI_INTEGER                              &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID &
                , 1001                                     &
                , SurfCOMM%COMM                            &
                , SurfExchange%SendRequest(iProc)          &
                , IERROR )
END DO ! iProc


! 4) Finish Received number of particles
DO iProc=1,SurfCOMM%nMPINeighbors
  CALL MPI_WAIT(SurfExchange%SendRequest(iProc),MPIStatus,IERROR)
  IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
,' MPI Communication error', IERROR)
  CALL MPI_WAIT(SurfExchange%RecvRequest(iProc),recv_status_list(:,iProc),IERROR)
  IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
          ,' MPI Communication error', IERROR)
END DO ! iProc

! allocate send and receive buffer
ALLOCATE(SurfSendBuf(SurfCOMM%nMPINeighbors))
ALLOCATE(SurfRecvBuf(SurfCOMM%nMPINeighbors))
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).GT.0)THEN
    ALLOCATE(SurfSendBuf(iProc)%content(2*SurfExchange%nSidesSend(iProc)),STAT=ALLOCSTAT)
    SurfSendBuf(iProc)%Content=-1
  END IF
  IF(SurfExchange%nSidesRecv(iProc).GT.0)THEN
    ALLOCATE(SurfRecvBuf(iProc)%content(2*SurfExchange%nSidesRecv(iProc)),STAT=ALLOCSTAT)
  END IF
END DO ! iProc=1,PartMPI%nMPINeighbors
 
! open receive buffer
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesRecv(iProc).EQ.0) CYCLE
  CALL MPI_IRECV( SurfRecvBuf(iProc)%content                   &
                , 2*SurfExchange%nSidesRecv(iProc)             &
                , MPI_DOUBLE_PRECISION                         &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID     &
                , 1004                                         &
                , SurfCOMM%COMM                                &
                , SurfExchange%RecvRequest(iProc)              & 
                , IERROR )
END DO ! iProc

! build message 
! after this message, the receiving process knows to which of his sides the sending process will send the 
  ! surface data
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).EQ.0) CYCLE
  iSendSide=0
  iPos=1
  DO iSide=nSides+1,nTotalSides
    SurfSideID=SurfMesh%SideIDToSurfID(iSide) 
    IF(SurfSideID.EQ.-1) CYCLE
    ! get elemid
    IF(iProc.EQ.PartHaloSideToProc(LOCAL_PROC_ID,iSide))THEN
      iSendSide=iSendSide+1
      ! get elemid
      ElemID=PartSideToElem(S2E_ELEM_ID,iSide)
      LocSideID = PartSideToElem(S2E_LOC_SIDE_ID,iSide)
      IF (ElemID.EQ.-1) THEN
        ElemID=PartSideToElem(S2E_NB_ELEM_ID,iSide)
        LocSideID = PartSideToElem(S2E_NB_LOC_SIDE_ID,iSide)
      END IF
      TargetElem=PartHaloElemToProc(NATIVE_ELEM_ID,ElemID)
      IF(ElemID.LE.PP_nElems)THEN
       IPWRITE(UNIT_stdOut,*) ' Error in PartSideToElem'
      END IF
      IF(ElemID.LE.1)THEN
       IPWRITE(UNIT_stdOut,*) ' Error in PartSideToElem'
      END IF
      SurfCOMM%MPINeighbor(iProc)%SendList(iSendSide)=SurfSideID
!       IPWRITE(*,*) 'negative elem id',PartHaloElemToProc(NATIVE_ELEM_ID,ElemID),PartSideToElem(S2E_LOC_SIDE_ID,iSide)
      SurfSendBuf(iProc)%content(iPos  )= REAL(TargetElem)
      SurfSendBuf(iProc)%content(iPos+1)= REAL(LocSideID)
      iPos=iPos+2
    END IF
  END DO ! iSide=nSides+1,nTotalSides
  IF(iSendSide.NE.SurfExchange%nSidesSend(iProc)) CALL abort(&
__STAMP__&
          ,' Message too short!',iProc)
  IF(ANY(SurfSendBuf(iProc)%content.LE.0))THEN  
    IPWRITE(UNIT_stdOut,*) ' nSendSides', SurfExchange%nSidesSend(iProc), ' to Proc ', iProc
    CALL abort(&
__STAMP__&
          ,' Sent NATIVE_ELEM_ID or LOCSIDEID is zero!')
  END IF
END DO

DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).EQ.0) CYCLE
  CALL MPI_ISEND( SurfSendBuf(iProc)%content               &
                , 2*SurfExchange%nSidesSend(iProc)         & 
                , MPI_DOUBLE_PRECISION                     &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID & 
                , 1004                                     &
                , SurfCOMM%COMM                            &   
                , SurfExchange%SendRequest(iProc)          &
                , IERROR )                                     
END DO ! iProc                                                

! 4) Finish Received number of particles
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).NE.0) THEN
    CALL MPI_WAIT(SurfExchange%SendRequest(iProc),MPIStatus,IERROR)
    IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
          ,' MPI Communication error', IERROR)
  END IF
  IF(SurfExchange%nSidesRecv(iProc).NE.0) THEN
    CALL MPI_WAIT(SurfExchange%RecvRequest(iProc),recv_status_list(:,iProc),IERROR)
    IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
          ,' MPI Communication error', IERROR)
  END IF
END DO ! iProc

! fill list with received side ids
! store the receiving data
DO iProc=1,SurfCOMM%nMPINeighbors
  ALLOCATE(SurfCOMM%MPINeighbor(iProc)%RecvList(SurfExchange%nSidesRecv(iProc)))
  IF(SurfExchange%nSidesRecv(iProc).EQ.0) CYCLE
  iPos=1
  DO iRecvSide=1,SurfExchange%nSidesRecv(iProc)
    NativeElemID   =INT(SurfRecvBuf(iProc)%content(iPos))
    NativeLocSideID=INT(SurfRecvBuf(iProc)%content(iPos+1))
!     IPWRITE(*,*) 'received- elemid, locsideid',NativeElemID,NativeLocSideID
    IF(NativeElemID.GT.PP_nElems)THEN
     CALL abort(&
__STAMP__&
          ,' Cannot send halo-data to other progs. big error! ', ElemID, REAL(PP_nElems))
    END IF
    SideID=PartElemToSide(E2S_SIDE_ID,NativeLocSideID,NativeElemID)

    IF(SideID.GT.nSides)THEN
      IPWRITE(UNIT_stdOut,*) ' Received wrong sideid. Is not a BC side! '
      IPWRITE(UNIT_stdOut,*) ' SideID, nBCSides, nSides ', SideID, nBCSides, nSides
      IPWRITE(UNIT_stdOut,*) ' ElemID, locsideid        ', NativeElemID, NativeLocSideID
      IPWRITE(UNIT_stdOut,*) ' Sending process has error in halo-region! ', SurfCOMM%MPINeighbor(iProc)%NativeProcID
     CALL abort(&
__STAMP__&
          ,' Big error in halo region! NativeLocSideID ', NativeLocSideID )
    END IF
    SurfSideID=SurfMesh%SideIDToSurfID(SideID)
    IF(SurfSideID.EQ.-1)THEN
     CALL abort(&
__STAMP__&
          ,' Side is not even a reflective BC side! ', SideID )
    END IF
    SurfCOMM%MPINeighbor(iProc)%RecvList(iRecvSide)=SurfSideID
    iPos=iPos+2
  END DO ! RecvSide=1,SurfExchange%nSidesRecv(iProc)-1,2
END DO ! iProc

DO iProc=1,SurfCOMM%nMPINeighbors
  SDEALLOCATE(SurfSendBuf(iProc)%content)
  SDEALLOCATE(SurfRecvBuf(iProc)%content)
  IF(SurfExchange%nSidesSend(iProc).GT.0) THEN
    ALLOCATE(SurfSendBuf(iProc)%content((SurfMesh%SampSize)*nDOF*SurfExchange%nSidesSend(iProc)))
    SurfSendBuf(iProc)%content=0.
  END IF
  IF(SurfExchange%nSidesRecv(iProc).GT.0) THEN
    ALLOCATE(SurfRecvBuf(iProc)%content((SurfMesh%SampSize)*nDOF*SurfExchange%nSidesRecv(iProc)))
    SurfRecvBuf(iProc)%content=0.
  END IF
END DO ! iProc

IF(nPorousBC.GT.0) THEN
  ALLOCATE(PorousBCSendBuf(SurfCOMM%nMPINeighbors))
  ALLOCATE(PorousBCRecvBuf(SurfCOMM%nMPINeighbors))
  DO iProc=1,SurfCOMM%nMPINeighbors
    IF(SurfExchange%nSidesSend(iProc).GT.0) THEN
      ALLOCATE(PorousBCSendBuf(iProc)%content_int(nPorousBCVars*nPorousBC*SurfExchange%nSidesSend(iProc)))
      PorousBCSendBuf(iProc)%content_int=0
    END IF
    IF(SurfExchange%nSidesRecv(iProc).GT.0) THEN
      ALLOCATE(PorousBCRecvBuf(iProc)%content_int(nPorousBCVars*nPorousBC*SurfExchange%nSidesRecv(iProc)))
      PorousBCRecvBuf(iProc)%content_int=0
    END IF
  END DO ! iProc
END IF

DEALLOCATE(recv_status_list)

CALL MPI_BARRIER(SurfCOMM%Comm,iError)

END SUBROUTINE GetHaloSurfMapping


SUBROUTINE ExchangeSurfData() 
!===================================================================================================================================
! exchange the surface data
! only processes with samling sides in their halo region and the original process participate on the communication
! structure is similar to particle communication
! each process sends his halo-information directly to the origin process by use of a list, containing the surfsideids for sending
! the receiving process adds the new data to his own sides
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Globals
USE MOD_Particle_Vars               ,ONLY:nSpecies,LiquidSimFlag,PartSurfaceModel
USE MOD_SurfaceModel_Vars           ,ONLY:Adsorption
USE MOD_Particle_Boundary_Vars      ,ONLY:SurfMesh,SurfComm,nSurfSample,SampWall
USE MOD_Particle_MPI_Vars           ,ONLY:SurfSendBuf,SurfRecvBuf,SurfExchange
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                         :: MessageSize,nValues,iSurfSide,SurfSideID
INTEGER                         :: iPos,p,q,iProc,iReact
INTEGER                         :: recv_status_list(1:MPI_STATUS_SIZE,1:SurfCOMM%nMPINeighbors)
!===================================================================================================================================

nValues = SurfMesh%SampSize*nSurfSample**2
! additional array entries for Coverage, Accomodation and recombination coefficient
IF(PartSurfaceModel.GT.0) nValues = nValues + ((nSpecies+1)+nSpecies+(Adsorption%RecombNum*nSpecies))*(nSurfSample)**2
! additional array entries for liquid surfaces
IF(LiquidSimFlag) nValues = nValues + (nSpecies+1)*nSurfSample**2
!
! open receive buffer
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesRecv(iProc).EQ.0) CYCLE
  MessageSize=SurfExchange%nSidesRecv(iProc)*nValues
  CALL MPI_IRECV( SurfRecvBuf(iProc)%content                   &
                , MessageSize                                  &
                , MPI_DOUBLE_PRECISION                         &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID     &
                , 1009                                         &
                , SurfCOMM%COMM                                &
                , SurfExchange%RecvRequest(iProc)              &
                , IERROR )
END DO ! iProc

! build message
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).EQ.0) CYCLE
  iPos=0
  SurfSendBuf(iProc)%content = 0.
  DO iSurfSide=1,SurfExchange%nSidesSend(iProc)
    SurfSideID=SurfCOMM%MPINeighbor(iProc)%SendList(iSurfSide)
    DO q=1,nSurfSample
      DO p=1,nSurfSample
        SurfSendBuf(iProc)%content(iPos+1:iPos+SurfMesh%SampSize)= SampWall(SurfSideID)%State(:,p,q)
        iPos=iPos+SurfMesh%SampSize
        IF (PartSurfaceModel.GT.0) THEN
          SurfSendBuf(iProc)%content(iPos+1:iPos+nSpecies+1)= SampWall(SurfSideID)%Adsorption(:,p,q)
          iPos=iPos+nSpecies+1
          SurfSendBuf(iProc)%content(iPos+1:iPos+nSpecies)= SampWall(SurfSideID)%Accomodation(:,p,q)
          iPos=iPos+nSpecies
          DO iReact=1,Adsorption%RecombNum
            SurfSendBuf(iProc)%content(iPos+1:iPos+nSpecies)= SampWall(SurfSideID)%Reaction(iReact,:,p,q)
            iPos=iPos+nSpecies
          END DO
        END IF
        IF (LiquidSimFlag) THEN
          SurfSendBuf(iProc)%content(iPos+1:iPos+nSpecies+1)= SampWall(SurfSideID)%Evaporation(:,p,q)
          iPos=iPos+nSpecies+1
        END IF
      END DO ! p=0,nSurfSample
    END DO ! q=0,nSurfSample
    SampWall(SurfSideID)%State(:,:,:)=0.
    IF (PartSurfaceModel.GT.0) THEN
      SampWall(SurfSideID)%Adsorption(:,:,:)=0.
      SampWall(SurfSideID)%Accomodation(:,:,:)=0.
      SampWall(SurfSideID)%Reaction(:,:,:,:)=0.
    END IF
    IF (LiquidSimFlag) THEN
      SampWall(SurfSideID)%Evaporation(:,:,:)=0.
    END IF
  END DO ! iSurfSide=1,nSurfExchange%nSidesSend(iProc)
END DO

! send message
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).EQ.0) CYCLE
  MessageSize=SurfExchange%nSidesSend(iProc)*nValues
  CALL MPI_ISEND( SurfSendBuf(iProc)%content               &
                , MessageSize                              &
                , MPI_DOUBLE_PRECISION                     &
                , SurfCOMM%MPINeighbor(iProc)%NativeProcID &
                , 1009                                     &
                , SurfCOMM%COMM                            &
                , SurfExchange%SendRequest(iProc)          &
                , IERROR )
END DO ! iProc                                                

! 4) Finish Received number of particles
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesSend(iProc).NE.0) THEN
    CALL MPI_WAIT(SurfExchange%SendRequest(iProc),MPIStatus,IERROR)
    IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
          ,' MPI Communication error', IERROR)
  END IF
  IF(SurfExchange%nSidesRecv(iProc).NE.0) THEN
    CALL MPI_WAIT(SurfExchange%RecvRequest(iProc),recv_status_list(:,iProc),IERROR)
    IF(IERROR.NE.MPI_SUCCESS) CALL abort(&
__STAMP__&
          ,' MPI Communication error', IERROR)
  END IF
END DO ! iProc

! add data do my list
DO iProc=1,SurfCOMM%nMPINeighbors
  IF(SurfExchange%nSidesRecv(iProc).EQ.0) CYCLE
  iPos=0
  DO iSurfSide=1,SurfExchange%nSidesRecv(iProc)
    SurfSideID=SurfCOMM%MPINeighbor(iProc)%RecvList(iSurfSide)
    DO q=1,nSurfSample
      DO p=1,nSurfSample
        SampWall(SurfSideID)%State(:,p,q)=SampWall(SurfSideID)%State(:,p,q) &
                                         +SurfRecvBuf(iProc)%content(iPos+1:iPos+SurfMesh%SampSize)
        iPos=iPos+SurfMesh%SampSize
        IF (PartSurfaceModel.GT.0) THEN
          SampWall(SurfSideID)%Adsorption(:,p,q)=SampWall(SurfSideID)%Adsorption(:,p,q) &
                                                +SurfRecvBuf(iProc)%content(iPos+1:iPos+nSpecies+1)
          iPos=iPos+nSpecies+1
          SampWall(SurfSideID)%Accomodation(:,p,q)=SampWall(SurfSideID)%Accomodation(:,p,q) &
                                                  +SurfRecvBuf(iProc)%content(iPos+1:iPos+nSpecies)
          iPos=iPos+nSpecies
          DO iReact=1,Adsorption%RecombNum
            SampWall(SurfSideID)%Reaction(iReact,:,p,q)=SampWall(SurfSideID)%Reaction(iReact,:,p,q) &
                                                       +SurfRecvBuf(iProc)%content(iPos+1:iPos+nSpecies)
            iPos=iPos+nSpecies
          END DO
        END IF
        IF (LiquidSimFlag) THEN
          SampWall(SurfSideID)%Evaporation(:,p,q)=SampWall(SurfSideID)%Evaporation(:,p,q) &
                                                     +SurfRecvBuf(iProc)%content(iPos+1:iPos+nSpecies+1)
          iPos=iPos+nSpecies+1
        END IF
      END DO ! p=0,nSurfSample
    END DO ! q=0,nSurfSample
  END DO ! iSurfSide=1,nSurfExchange%nSidesSend(iProc)
  SurfRecvBuf(iProc)%content = 0.
END DO ! iProc

END SUBROUTINE ExchangeSurfData


SUBROUTINE MapInnerSurfData() 
!===================================================================================================================================
! Map the surface data from inner BCsSlaveSide to HaloSide
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Globals
USE MOD_Particle_Boundary_Vars,     ONLY:SurfMesh,nSurfSample,SampWall,PartBound
USE MOD_Mesh_Vars,                  ONLY:nBCSides,nSides,BC
USE MOD_Particle_Mesh_Vars,         ONLY:PartSideToElem
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                         :: StartSurfSide,iSide,TargetHaloSide,q,p,SurfSideID,SurfSideHaloID
!===================================================================================================================================

StartSurfSide = SurfMesh%nBCSides + SurfMesh%nInnerSides
IF(SurfMesh%nSides.GT.StartSurfSide) THEN ! There are reflective inner BCs on SlaveSide
  DO iSide=nBCSides+1,nSides
    IF(BC(iSide).EQ.0) CYCLE
    IF (PartBound%TargetBoundCond(PartBound%MapToPartBC(BC(iSide))).EQ.PartBound%ReflectiveBC) THEN
      IF(PartSideToElem(S2E_ELEM_ID,iSide).EQ.-1) THEN ! SlaveSide
        DO q=1,nSurfSample
          DO p=1,nSurfSample
            TargetHaloSide = SurfMesh%innerBCSideToHaloMap(iSide)
            SurfSideID=SurfMesh%SideIDToSurfID(iSide)
            SurfSideHaloID=SurfMesh%SideIDToSurfID(TargetHaloSide)
            SampWall(SurfSideHaloID)%State(:,p,q)=SampWall(SurfSideHaloID)%State(:,p,q) &
                                                  +SampWall(SurfSideID)%State(:,p,q)
          END DO
        END DO
      END IF
    END IF
  END DO 
END IF


END SUBROUTINE MapInnerSurfData
#endif /*MPI*/

SUBROUTINE WriteSurfSampleToHDF5(MeshFileName,OutputTime)
!===================================================================================================================================
!> write the final values of the surface sampling to a HDF5 state file
!> additional performs all the final required computations
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Globals
USE MOD_IO_HDF5
USE MOD_Globals_Vars,               ONLY:ProjectName
USE MOD_Particle_Boundary_Vars,     ONLY:nSurfSample,SurfMesh,offSetSurfSide,offsetInnerSurfSide,nPorousBC
USE MOD_DSMC_Vars,                  ONLY:MacroSurfaceVal,MacroSurfaceSpecVal, CollisMode
USE MOD_Particle_Vars,              ONLY:nSpecies,PartSurfaceModel
USE MOD_HDF5_Output,                ONLY:WriteAttributeToHDF5,WriteArrayToHDF5,WriteHDF5Header
USE MOD_Particle_Boundary_Vars,     ONLY:SurfCOMM,nSurfBC,SurfBCName
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
CHARACTER(LEN=*),INTENT(IN)          :: MeshFileName
REAL,INTENT(IN)                      :: OutputTime
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
CHARACTER(LEN=255)                  :: FileName,FileString,Statedummy
CHARACTER(LEN=255)                  :: H5_Name
CHARACTER(LEN=255)                  :: NodeTypeTemp
CHARACTER(LEN=255)                  :: SpecID, PBCID
CHARACTER(LEN=255),ALLOCATABLE      :: Str2DVarNames(:)
INTEGER                             :: nVar2D, nVar2D_Spec, nVar2D_Total, nVarCount, iSpec, iPBC, nOutputSides
REAL                                :: tstart,tend
!===================================================================================================================================

#ifdef MPI
CALL MPI_BARRIER(SurfCOMM%COMM,iERROR)
IF(SurfMesh%nSides.EQ.0) RETURN
#endif /*MPI*/
IF(SurfCOMM%MPIOutputRoot)THEN
  WRITE(UNIT_stdOut,'(a)',ADVANCE='NO')' WRITE DSMCSurfSTATE TO HDF5 FILE...'
  tstart=LOCALTIME()
END IF

FileName=TIMESTAMP(TRIM(ProjectName)//'_DSMCSurfState',OutputTime)
FileString=TRIM(FileName)//'.h5'


! Create dataset attribute "SurfVarNames"
IF (PartSurfaceModel.GT.0) THEN
  nVar2D = 6
  nVar2D_Spec=4
ELSE
  nVar2D = 5
  nVar2D_Spec=1
END IF

IF(nPorousBC.GT.0)  nVar2D = nVar2D + nPorousBC

nVar2D_Total = nVar2D + nVar2D_Spec*nSpecies

! Generate skeleton for the file with all relevant data on a single proc (MPIRoot)
#ifdef MPI
IF(SurfCOMM%MPIOutputRoot)THEN
#endif
  CALL OpenDataFile(FileString,create=.TRUE.,single=.TRUE.,readOnly=.FALSE.)
  Statedummy = 'DSMCSurfState'

  ! Write file header
  CALL WriteHDF5Header(Statedummy,File_ID)
  CALL WriteAttributeToHDF5(File_ID,'DSMC_nSurfSample',1,IntegerScalar=nSurfSample)
  CALL WriteAttributeToHDF5(File_ID,'DSMC_nSpecies',1,IntegerScalar=nSpecies)
  CALL WriteAttributeToHDF5(File_ID,'DSMC_CollisMode',1,IntegerScalar=CollisMode)
  CALL WriteAttributeToHDF5(File_ID,'MeshFile',1,StrScalar=(/TRIM(MeshFileName)/))
  CALL WriteAttributeToHDF5(File_ID,'Time',1,RealScalar=OutputTime)
  CALL WriteAttributeToHDF5(File_ID,'BC_Surf',nSurfBC,StrArray=SurfBCName)
  CALL WriteAttributeToHDF5(File_ID,'N',1,IntegerScalar=nSurfSample)
  NodeTypeTemp='VISU'
  CALL WriteAttributeToHDF5(File_ID,'NodeType',1,StrScalar=(/NodeTypeTemp/))

  ALLOCATE(Str2DVarNames(1:nVar2D_Total))
  nVarCount=0
  DO iSpec=1,nSpecies
    WRITE(SpecID,'(I3.3)') iSpec
    Str2DVarNames(nVarCount+1) ='Spec'//TRIM(SpecID)//'_Counter'
    IF (PartSurfaceModel.GT.0) THEN
      Str2DVarNames(nVarCount+2) ='Spec'//TRIM(SpecID)//'_Accomodation'
      Str2DVarNames(nVarCount+3) ='Spec'//TRIM(SpecID)//'_Coverage'
      Str2DVarNames(nVarCount+4) ='Spec'//TRIM(SpecID)//'_Recomb_Coeff'
    END IF
    nVarCount=nVarCount+nVar2D_Spec
  END DO ! iSpec=1,nSpecies

  ! fill varnames for total values
  Str2DVarNames(nVarCount+1) ='ForcePerAreaX'
  Str2DVarNames(nVarCount+2) ='ForcePerAreaY'
  Str2DVarNames(nVarCount+3) ='ForcePerAreaZ'
  Str2DVarNames(nVarCount+4) ='HeatFlux'
  Str2DVarNames(nVarCount+5) ='Counter_Total'
  nVarCount = nVarCount + 5
  IF (PartSurfaceModel.GT.0) THEN
    Str2DVarNames(nVarCount+1) ='HeatFlux_Portion_Cat'
    nVarCount = nVarCount + 1
  END IF

  IF(nPorousBC.GT.0) THEN
    DO iPBC = 1, nPorousBC
      WRITE(PBCID,'(I2.2)') iPBC
      Str2DVarNames(nVarCount+iPBC) = 'PorousBC'//TRIM(PBCID)//'_PumpCapacity'
    END DO
    nVarCount = nVarCount + nPorousBC
  END IF

  CALL WriteAttributeToHDF5(File_ID,'VarNamesSurface',nVar2D_Total,StrArray=Str2DVarNames)

  CALL CloseDataFile()
  DEALLOCATE(Str2DVarNames)
#ifdef MPI
END IF

CALL MPI_BARRIER(SurfCOMM%OutputCOMM,iERROR)
#endif /*MPI*/

!   IF(SurfCOMM%nProcs.GT.1)THEN
CALL OpenDataFile(FileString,create=.FALSE.,single=.FALSE.,readOnly=.FALSE.,communicatorOpt=SurfCOMM%OutputCOMM)
!   ELSE
!     CALL OpenDataFile(FileString,create=.FALSE.,single=.TRUE.)
!   END IF

nVarCount=0
WRITE(H5_Name,'(A)') 'SurfaceData'
ASSOCIATE (&
      nVar2D_Total         => INT(nVar2D_Total,IK)          ,&
      nSurfSample          => INT(nSurfSample,IK)           ,&
      nGlobalSides         => INT(SurfMesh%nGlobalSides,IK) ,&
      LocalnBCSides        => INT(SurfMesh%nBCSides,IK)      ,&
      nInnerSides          => INT(SurfMesh%nInnerSides,IK)  ,&
      offsetSurfSide       => INT(offsetSurfSide,IK)        ,&
      offsetInnerSurfSide  => INT(offsetInnerSurfSide,IK)   ,&
      nVar2D_Spec          => INT(nVar2D_Spec,IK)           ,&
      nVar2D               => INT(nVar2D,IK) )
  DO iSpec = 1,nSpecies
    CALL WriteArrayToHDF5(DataSetName=H5_Name             , rank=4                                      , &
                            nValGlobal =(/nVar2D_Total      , nSurfSample , nSurfSample , nGlobalSides/)  , &
                            nVal       =(/nVar2D_Spec       , nSurfSample , nSurfSample , LocalnBCSides/)        , &
                            offset     =(/INT(nVarCount,IK) , 0_IK        , 0_IK        , offsetSurfSide/), &
                            collective =.TRUE.,&
                            RealArray=MacroSurfaceSpecVal(1:nVar2D_Spec,1:nSurfSample,1:nSurfSample,1:LocalnBCSides,iSpec))
    nVarCount = nVarCount + INT(nVar2D_Spec)
  END DO
  CALL WriteArrayToHDF5(DataSetName=H5_Name            , rank=4                                     , &
                        nValGlobal =(/nVar2D_Total     , nSurfSample, nSurfSample , nGlobalSides/)  , &
                        nVal       =(/nVar2D           , nSurfSample, nSurfSample , LocalnBCSides/)        , &
                        offset     =(/INT(nVarCount,IK), 0_IK       , 0_IK        , offsetSurfSide/), &
                        collective =.TRUE.         ,&
                        RealArray=MacroSurfaceVal(1:nVar2D,1:nSurfSample,1:nSurfSample,1:LocalnBCSides))
  ! Output of InnerSurfSide Array
  ! HDF5 Output: collective=false is required to avoid a deadlock, since not all procs in this routine have inner sides
  IF(nInnerSides.GT.0) THEN
    nOutputSides = LocalnBCSides + nInnerSides
    nVarCount=0
    DO iSpec = 1,nSpecies
      CALL WriteArrayToHDF5(DataSetName=H5_Name             , rank=4                                      , &
                      nValGlobal =(/nVar2D_Total      , nSurfSample , nSurfSample , nGlobalSides/)  , &
                      nVal       =(/nVar2D_Spec       , nSurfSample , nSurfSample , nInnerSides/)        , &
                      offset     =(/INT(nVarCount,IK) , 0_IK        , 0_IK        , offsetInnerSurfSide/), &
                      collective =.FALSE.,&
                      RealArray=MacroSurfaceSpecVal(1:nVar2D_Spec,1:nSurfSample,1:nSurfSample,LocalnBCSides+1:nOutputSides,iSpec))
      nVarCount = nVarCount + INT(nVar2D_Spec)
    END DO
    CALL WriteArrayToHDF5(DataSetName=H5_Name            , rank=4                                     , &
                          nValGlobal =(/nVar2D_Total     , nSurfSample, nSurfSample , nGlobalSides/)  , &
                          nVal       =(/nVar2D           , nSurfSample, nSurfSample , nInnerSides/)        , &
                          offset     =(/INT(nVarCount,IK), 0_IK       , 0_IK        , offsetInnerSurfSide/), &
                          collective =.FALSE.         ,&
                          RealArray=MacroSurfaceVal(1:nVar2D,1:nSurfSample,1:nSurfSample,LocalnBCSides+1:nOutputSides))
  END IF
END ASSOCIATE

CALL CloseDataFile()

IF(SurfCOMM%MPIOutputROOT)THEN
  tend=LOCALTIME()
  WRITE(UNIT_stdOut,'(A,F0.3,A)',ADVANCE='YES')'DONE  [',tend-tstart,'s]'
END IF

END SUBROUTINE WriteSurfSampleToHDF5


SUBROUTINE ReadAnalyzeSurfCollisToHDF5()
!===================================================================================================================================
! Reading AnalyzeSurfCollis-Data from hdf5 file for restart
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_PreProc
USE MOD_HDF5_input,         ONLY: OpenDataFile,CloseDataFile,ReadArray,File_ID,GetDataSize,nDims,HSize,ReadAttribute
USE MOD_Particle_Vars,      ONLY: nSpecies
USE MOD_PICDepo_Vars,       ONLY: LastAnalyzeSurfCollis, r_SF !, SFResampleAnalyzeSurfCollis
USE MOD_Particle_Boundary_Vars,ONLY: nPartBound, AnalyzeSurfCollis
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
CHARACTER(LEN=255)             :: Filename, H5_Name
INTEGER                        :: PartDataSize, iSpec
REAL, ALLOCATABLE              :: PartSpecData(:,:,:)
INTEGER                        :: TotalNumberMPF, counter2, counter, BCTotalNumberMPF, counter3
REAL                           :: TotalFlowrateMPF, RandVal, BCTotalFlowrateMPF
LOGICAL,ALLOCATABLE            :: PartDone(:)
!===================================================================================================================================
  FileName = TRIM(LastAnalyzeSurfCollis%DSMCSurfCollisRestartFile)
  SWRITE(UNIT_stdOut,*)'Reading Particles from DSMCSurfCollis-File:',TRIM(FileName)

  !-- initialize data (check if file exists and determine size of arrays)
  PartDataSize=10
  IF(MPIRoot) THEN
    IF(.NOT.FILEEXISTS(FileName))  CALL abort(__STAMP__, &
          'DSMCSurfCollis-File "'//TRIM(FileName)//'" does not exist',999,999.)
    CALL OpenDataFile(TRIM(FileName),create=.FALSE.,single=.TRUE.,readOnly=.TRUE.)
    DO iSpec=1,nSpecies
      WRITE(H5_Name,'(A,I3.3)') 'SurfCollisData_Spec',iSpec
      CALL GetDataSize(File_ID,TRIM(H5_Name),nDims,HSize)
      AnalyzeSurfCollis%Number(iSpec)=INT(HSize(1),4) !global number of particles
      IF ( INT(HSize(nDims),4) .NE. PartDataSize ) THEN
        CALL Abort(&
        __STAMP__,&
        'Error in ReadAnalyzeSurfCollisToHDF5. Array has size of ',nDims,REAL(INT(HSize(nDims),4)))
      END IF
      DEALLOCATE(HSize)
    END DO !iSpec
    CALL CloseDataFile()
    AnalyzeSurfCollis%Number(nSpecies+1) = SUM( AnalyzeSurfCollis%Number(1:nSpecies) )
  END IF !MPIRoot
#ifdef MPI
  CALL MPI_BCAST(AnalyzeSurfCollis%Number(:),nSpecies+1,MPI_INTEGER,0,MPI_COMM_WORLD,iError)
#endif
  TotalNumberMPF=AnalyzeSurfCollis%Number(nSpecies+1)
  ALLOCATE( PartSpecData(nSpecies,MAXVAL(AnalyzeSurfCollis%Number(1:nSpecies)),PartDataSize) )

  !-- open file for actual read-in
#ifdef MPI
  CALL MPI_BARRIER(MPI_COMM_WORLD,iError)
#endif
  CALL OpenDataFile(TRIM(FileName),create=.FALSE.,single=.FALSE.,readOnly=.TRUE.,communicatorOpt=MPI_COMM_WORLD)
  ! Read in state
  DO iSpec=1,nSpecies
    WRITE(H5_Name,'(A,I3.3)') 'SurfCollisData_Spec',iSpec
    IF (AnalyzeSurfCollis%Number(iSpec).GT.0) THEN
      ! Associate construct for integer KIND=8 possibility
      ASSOCIATE (&
            AnalyzeSurfCollis  => INT(AnalyzeSurfCollis%Number(iSpec),IK) ,&
            PartDataSize       => INT(PartDataSize,IK)                    )
        CALL ReadArray(TRIM(H5_Name) , 2 , (/AnalyzeSurfCollis          , PartDataSize/)      , &
            0_IK                     , 1 , RealArray=PartSpecData(iSpec , 1:AnalyzeSurfCollis , 1:PartDataSize))
      END ASSOCIATE
    END IF
  END DO !iSpec
  CALL ReadAttribute(File_ID,'TotalFlowrateMPF',1,RealScalar=TotalFlowrateMPF)
  SWRITE(UNIT_stdOut,*)'DONE!' 
  CALL CloseDataFile() 

!--save data
  IF (TotalNumberMPF.GT.0) THEN
    ! determine number of parts at BC of interest
    BCTotalNumberMPF=0
    DO iSpec=1,nSpecies
      DO counter=1,AnalyzeSurfCollis%Number(iSpec)
        IF (INT(PartSpecData(iSpec,counter,10)).LT.1 .OR. INT(PartSpecData(iSpec,counter,10)).GT.nPartBound) THEN
          CALL Abort(&
            __STAMP__,&
            'Error 3 in AnalyzeSurfCollis!')
        ELSE IF ( ANY(LastAnalyzeSurfCollis%BCs.EQ.0) .OR. ANY(LastAnalyzeSurfCollis%BCs.EQ.INT(PartSpecData(iSpec,counter,10))) ) THEN
          BCTotalNumberMPF = BCTotalNumberMPF + 1
        END IF
      END DO
    END DO
    IF (BCTotalNumberMPF.EQ.0) THEN
      SWRITE(*,*) 'WARNING in ReadAnalyzeSurfCollisToHDF5: no parts found for BC of interest!'
      RETURN
    ELSE IF (BCTotalNumberMPF.EQ.AnalyzeSurfCollis%Number(nSpecies+1)) THEN
      BCTotalFlowrateMPF=TotalFlowrateMPF
      SWRITE(*,*) 'ReadAnalyzeSurfCollisToHDF5: all particles are used for resampling...'
    ELSE
      BCTotalFlowrateMPF=TotalFlowrateMPF*REAL(BCTotalNumberMPF)/REAL(AnalyzeSurfCollis%Number(nSpecies+1))
      SWRITE(*,*) 'ReadAnalyzeSurfCollisToHDF5: The fraction of particles used for resampling is: ',BCTotalFlowrateMPF/TotalFlowrateMPF
    END IF

    IF (LastAnalyzeSurfCollis%ReducePartNumber) THEN !reduce saved number of parts to MaxPartNumber
      LastAnalyzeSurfCollis%PartNumberSamp=MIN(BCTotalNumberMPF,LastAnalyzeSurfCollis%PartNumberReduced)
      ALLOCATE(PartDone(1:TotalNumberMPF))
      PartDone(:)=.FALSE.
    ELSE
      LastAnalyzeSurfCollis%PartNumberSamp=BCTotalNumberMPF
    END IF
    SWRITE(*,*) 'Number of saved particles for SFResampleAnalyzeSurfCollis: ',LastAnalyzeSurfCollis%PartNumberSamp
    SDEALLOCATE(LastAnalyzeSurfCollis%WallState)
    SDEALLOCATE(LastAnalyzeSurfCollis%Species)
    ALLOCATE(LastAnalyzeSurfCollis%WallState(6,LastAnalyzeSurfCollis%PartNumberSamp))
    ALLOCATE(LastAnalyzeSurfCollis%Species(LastAnalyzeSurfCollis%PartNumberSamp))
    LastAnalyzeSurfCollis%pushTimeStep = HUGE(LastAnalyzeSurfCollis%pushTimeStep)

    ! Add particle to list
    counter2 = 0
    DO counter = 1, LastAnalyzeSurfCollis%PartNumberSamp
      IF (LastAnalyzeSurfCollis%ReducePartNumber) THEN !reduce saved number of parts (differently for each proc. Could be changed)
        DO !get random (equal!) position between [1,TotalNumberMPF] and accept if .NOT.PartDone and with right BC
          CALL RANDOM_NUMBER(RandVal)
          counter2 = MIN(1+INT(RandVal*REAL(TotalNumberMPF)),TotalNumberMPF)
          IF (.NOT.PartDone(counter2)) THEN
            counter3=counter2
            iSpec=nSpecies
            DO !determine in which species-"batch" the counter is located (use logical since it is used for ReducePartNumber anyway)
              IF (iSpec.EQ.1) THEN
                IF ( counter2 .GE. 1 ) THEN
                  EXIT
                ELSE
                  CALL Abort(&
                    __STAMP__, &
                    'Error in SFResampleAnalyzeSurfCollis. Could not determine iSpec for counter2 ',counter2)
                END IF
              ELSE IF ( counter2 - SUM(AnalyzeSurfCollis%Number(1:iSpec-1)) .GE. 1 ) THEN
                EXIT
              ELSE
                iSpec = iSpec - 1
              END IF
            END DO
            IF (iSpec.GT.1) THEN
              counter2 = counter2 - SUM(AnalyzeSurfCollis%Number(1:iSpec-1))
            END IF
            IF (counter2 .GT. AnalyzeSurfCollis%Number(iSpec)) THEN
              CALL Abort(&
                __STAMP__, &
                'Error in SFResampleAnalyzeSurfCollis. Determined iSpec is wrong for counter2 ',counter2)
            END IF
            IF (( ANY(LastAnalyzeSurfCollis%BCs.EQ.0) .OR. ANY(LastAnalyzeSurfCollis%BCs.EQ.PartSpecData(iSpec,counter2,10)) )) THEN
              PartDone(counter3)=.TRUE.
              EXIT
            END IF
          END IF
        END DO
      ELSE
        counter2 = counter
        iSpec=nSpecies
        DO !determine in which species-"batch" the counter is located (use logical since it is used for ReducePartNumber anyway)
          IF (iSpec.EQ.1) THEN
            IF ( counter2 .GE. 1 ) THEN
              EXIT
            ELSE
              CALL Abort(&
                __STAMP__, &
                'Error in SFResampleAnalyzeSurfCollis. Could not determine iSpec for counter2 ',counter2)
            END IF
          ELSE IF ( counter2 - SUM(AnalyzeSurfCollis%Number(1:iSpec-1)) .GE. 1 ) THEN
            EXIT
          ELSE
            iSpec = iSpec - 1
          END IF
        END DO
        IF (iSpec.GT.1) THEN
          counter2 = counter2 - SUM(AnalyzeSurfCollis%Number(1:iSpec-1))
        END IF
        IF (counter2 .GT. AnalyzeSurfCollis%Number(iSpec)) THEN
          CALL Abort(&
            __STAMP__, &
            'Error in SFResampleAnalyzeSurfCollis. Determined iSpec is wrong for counter2 ',counter2)
        END IF
      END IF
      LastAnalyzeSurfCollis%WallState(:,counter) = PartSpecData(iSpec,counter2,1:6)
      LastAnalyzeSurfCollis%Species(counter) = iSpec
      IF (ANY(LastAnalyzeSurfCollis%SpeciesForDtCalc.EQ.0) .OR. &
          ANY(LastAnalyzeSurfCollis%SpeciesForDtCalc.EQ.LastAnalyzeSurfCollis%Species(counter))) &
        LastAnalyzeSurfCollis%pushTimeStep = MIN( LastAnalyzeSurfCollis%pushTimeStep &
        , DOT_PRODUCT(LastAnalyzeSurfCollis%NormVecOfWall,LastAnalyzeSurfCollis%WallState(4:6,counter)) )
    END DO

    IF (LastAnalyzeSurfCollis%pushTimeStep .LE. 0.) THEN
      CALL Abort(&
        __STAMP__,&
        'Error with SFResampleAnalyzeSurfCollis. Something is wrong with velocities or NormVecOfWall!',&
        999,LastAnalyzeSurfCollis%pushTimeStep)
    ELSE
      LastAnalyzeSurfCollis%pushTimeStep = r_SF / LastAnalyzeSurfCollis%pushTimeStep !dt required for smallest projected velo to cross r_SF
      LastAnalyzeSurfCollis%PartNumberDepo = NINT(BCTotalFlowrateMPF * LastAnalyzeSurfCollis%pushTimeStep)
      SWRITE(*,'(A,E12.5,x,I0)') 'Total Flowrate and to be inserted number of MP for SFResampleAnalyzeSurfCollis: ' &
        ,BCTotalFlowrateMPF, LastAnalyzeSurfCollis%PartNumberDepo
      IF (LastAnalyzeSurfCollis%PartNumberDepo .GT. LastAnalyzeSurfCollis%PartNumberSamp) THEN
        SWRITE(*,*) 'WARNING: PartNumberDepo .GT. PartNumberSamp!'
      END IF
      IF (LastAnalyzeSurfCollis%PartNumberDepo .GT. LastAnalyzeSurfCollis%PartNumThreshold) THEN
        CALL Abort(&
          __STAMP__,&
          'Error with SFResampleAnalyzeSurfCollis: PartNumberDepo .gt. PartNumThreshold',&
          LastAnalyzeSurfCollis%PartNumberDepo,r_SF/LastAnalyzeSurfCollis%pushTimeStep)
      END IF
    END IF
  END IF !TotalNumberMPF.GT.0

END SUBROUTINE ReadAnalyzeSurfCollisToHDF5


SUBROUTINE FinalizeParticleBoundarySampling() 
!===================================================================================================================================
! deallocate everything
!===================================================================================================================================
! MODULES                                                                                                                          !
!----------------------------------------------------------------------------------------------------------------------------------!
USE MOD_Particle_Boundary_Vars
#ifdef MPI
USE MOD_Particle_MPI_Vars           ,ONLY:SurfSendBuf,SurfRecvBuf,SurfExchange,PartHaloSideToProc
#endif /*MPI*/
!----------------------------------------------------------------------------------------------------------------------------------!
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES 
!----------------------------------------------------------------------------------------------------------------------------------!
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER :: iProc,iSurfSide
!===================================================================================================================================

SDEALLOCATE(XiEQ_SurfSample)
SDEALLOCATE(SurfMesh%SurfaceArea)
SDEALLOCATE(SurfMesh%SideIDToSurfID)
SDEALLOCATE(SurfMesh%SurfIDToSideID)
!SDALLOCATE(SampWall%Energy)
!SDEALLOCATE(SampWall%Force)
!SDEALLOCATE(SampWall%Counter)
DO iSurfSide=1,SurfMesh%nTotalSides
  SDEALLOCATE(SampWall(iSurfSide)%State)
  SDEALLOCATE(SampWall(iSurfSide)%Adsorption)
  SDEALLOCATE(SampWall(iSurfSide)%Accomodation)
  SDEALLOCATE(SampWall(iSurfSide)%Reaction)
END DO
SDEALLOCATE(SurfBCName)
SDEALLOCATE(SampWall)
#ifdef MPI
SDEALLOCATE(PartHaloSideToProc)
SDEALLOCATE(SurfExchange%nSidesSend)
SDEALLOCATE(SurfExchange%nSidesRecv)
SDEALLOCATE(SurfExchange%SendRequest)
SDEALLOCATE(SurfExchange%RecvRequest)
DO iProc=1,SurfCOMM%nMPINeighbors
  IF (ALLOCATED(SurfSendBuf))THEN
    SDEALLOCATE(SurfSendBuf(iProc)%content)
  END IF
  IF (ALLOCATED(SurfRecvBuf))THEN
    SDEALLOCATE(SurfRecvBuf(iProc)%content)
  END IF
  IF (ALLOCATED(SurfCOMM%MPINeighbor))THEN
    SDEALLOCATE(SurfCOMM%MPINeighbor(iProc)%SendList)
    SDEALLOCATE(SurfCOMM%MPINeighbor(iProc)%RecvList)
  END IF
END DO ! iProc=1,PartMPI%nMPINeighbors
SDEALLOCATE(SurfCOMM%MPINeighbor)
SDEALLOCATE(SurfSendBuf)
SDEALLOCATE(SurfRecvBuf)
SDEALLOCATE(OffSetSurfSideMPI)
SDEALLOCATE(OffSetInnerSurfSideMPI)
#endif /*MPI*/
SDEALLOCATE(CalcSurfCollis%SpeciesFlags)
SDEALLOCATE(AnalyzeSurfCollis%Data)
SDEALLOCATE(AnalyzeSurfCollis%Spec)
SDEALLOCATE(AnalyzeSurfCollis%BCid)
SDEALLOCATE(AnalyzeSurfCollis%Number)
!SDEALLOCATE(AnalyzeSurfCollis%Rate)
SDEALLOCATE(AnalyzeSurfCollis%BCs)
END SUBROUTINE FinalizeParticleBoundarySampling

END MODULE MOD_Particle_Boundary_Sampling
