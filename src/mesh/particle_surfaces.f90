#include "boltzplatz.h"

MODULE MOD_Particle_Surfaces
!===================================================================================================================================
! Contains subroutines to build the requiered data to track particles on (curviilinear) meshes, etc.
!===================================================================================================================================
! MODULES
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
PRIVATE
!-----------------------------------------------------------------------------------------------------------------------------------
! GLOBAL VARIABLES (PUBLIC)
!-----------------------------------------------------------------------------------------------------------------------------------
! Public Part ----------------------------------------------------------------------------------------------------------------------

INTERFACE GetBiLinearPlane
  MODULE PROCEDURE GetBiLinearPlane
END INTERFACE

INTERFACE InitParticleSurfaces
  MODULE PROCEDURE InitParticleSurfaces
END INTERFACE

INTERFACE FinalizeParticleSurfaces
  MODULE PROCEDURE FinalizeParticleSurfaces
END INTERFACE

INTERFACE CalcBiLinearNormVec
  MODULE PROCEDURE CalcBiLinearNormVec
END INTERFACE

INTERFACE GetSuperSampledSurface
  MODULE PROCEDURE GetSuperSampledSurface
END INTERFACE

INTERFACE CalcNormVec
  MODULE PROCEDURE CalcNormVec
END INTERFACE

PUBLIC::GetBiLinearPlane, InitParticleSurfaces, FinalizeParticleSurfaces, CalcBiLinearNormVec, GetSuperSampledSurface, &
        CalcNormVec

!===================================================================================================================================

CONTAINS

SUBROUTINE InitParticleSurfaces()
!===================================================================================================================================
! read required parameters
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Particle_Surfaces_vars
USE MOD_Preproc
USE MOD_Mesh_Vars,                  ONLY:nSides,ElemToSide,SideToElem
USE MOD_ReadInTools,                ONLY:GETREAL,GETINT
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                         :: iElem,ilocSide,SideID,flip
!===================================================================================================================================

IF(ParticleSurfaceInitIsDone) RETURN
SWRITE(UNIT_StdOut,'(132("-"))')
SWRITE(UNIT_stdOut,'(A)')' INIT PARTICLE SURFACES ...!'

epsilonbilinear = GETREAL('eps-bilinear','1e-6')
epsilontol      = GETREAL('epsOne','1e-12')
epsilonOne      = 1.0 + epsilontol
!NPartCurved     = GETINT('NPartCurved','1')
!IF(NPartCurved.GT.1) DoPartCurved=.TRUE.

! construct connections to neighbor elems
ALLOCATE( neighborElemID    (1:6,1:PP_nElems) &
        , neighborlocSideID (1:6,1:PP_nElems) )
neighborElemID=-1
neighborlocSideID=-1

DO iElem=1,PP_nElems
  DO ilocSide=1,6
    flip = ElemToSide(E2S_FLIP,ilocSide,iElem)
    SideID = ElemToSide(E2S_SIDE_ID,ilocSide,iElem)
    IF(flip.EQ.0)THEN
      ! SideID of slave
      neighborlocSideID(ilocSide,iElem)=SideToElem(S2E_NB_LOC_SIDE_ID,SideID)
      neighborElemID   (ilocSide,iElem)=SideToElem(S2E_NB_ELEM_ID,SideID)
    ELSE
      ! SideID of master
      neighborlocSideID(ilocSide,iElem)=SideToElem(S2E_LOC_SIDE_ID,SideID)
      neighborElemID   (ilocSide,iElem)=SideToElem(S2E_ELEM_ID,SideID)
    END IF
  END DO ! ilocSide
END DO ! Elem

IF(.NOT.DoPartCurved)THEN
  ALLOCATE( SideIsPlanar(nSides)            &
          , SideDistance(nSides)            &
          , BiLinearCoeff(1:3,1:4,1:nSides) )
          !, nElemBCSides(PP_nElems)         &
  SideIsPlanar=.FALSE.
  CALL GetBiLinearPlane()
!ELSE
!  ALLOCATE( SuperSampledNodes(1:3,0:NPartCurved,0:NPartCurved,nSides)               &
!          , SuperSampledBiLinearCoeff(1:3,1:4,1:NPartCurved,1:NPartCurved,1:nSides) )
  !kCALL GetSuperSampledPlane()
END IF
ParticleSurfaceInitIsDone=.TRUE.
SWRITE(UNIT_stdOut,'(A)')' INIT PARTICLE SURFACES DONE!'
SWRITE(UNIT_StdOut,'(132("-"))')

END SUBROUTINE InitParticleSurfaces

SUBROUTINE FinalizeParticleSurfaces()
!===================================================================================================================================
! read required parameters
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Particle_Surfaces_vars
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!===================================================================================================================================

SDEALLOCATE(SideIsPlanar)
SDEALLOCATE(BiLinearCoeff)
SDEALLOCATE(SideNormVec)
SDEALLOCATE(SideDistance)
SDEALLOCATE(SuperSampledNodes)
SDEALLOCATE(SuperSampledBiLinearCoeff)
ParticleSurfaceInitIsDone=.FALSE.

END SUBROUTINE FinalizeParticleSurfaces

SUBROUTINE GetBilinearPlane()
!===================================================================================================================================
! computes the required coefficients for a bi-linear plane and performs the decision between planar and bi-linear planes
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Preproc
USE MOD_Mesh_Vars,                ONLY:nSides,ElemToSide
USE MOD_Particle_Vars,            ONLY:GEO
USE MOD_Particle_Surfaces_Vars,   ONLY:epsilonbilinear, SideIsPlanar,BiLinearCoeff, SideNormVec, SideDistance
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT/OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
LOGICAL,ALLOCATABLE               :: SideIsDone(:)
REAL                              :: Displacement,nlength
INTEGER                           :: iElem,ilocSide, SideID,iNode,iSide
! debug information
INTEGER                           :: nBilinear,nPlanar
!===================================================================================================================================

ALLOCATE( SideIsDone(1:nSides) )
SideIsDone=.FALSE.
nBiLinear=0
nPlanar=0

DO iElem=1,PP_nElems ! caution, if particles are not seeded in the whole domain
  DO ilocSide=1,6
    SideID=ElemToSide(E2S_SIDE_ID,ilocSide,iElem) 
    IF(.NOT.SideIsDone(SideID))THEN

      ! for ray-bi-linear patch intersection see. ramsay
      ! compute the bi-linear coefficients for this side
      ! caution: the parameter space is [-1;1] x [-1;1] instead of [0,1]x[0,2] 
      ! the numbering of the nodes should be counterclockwise 
      ! DEBUGGGG!!!!!!!!!!!!!!!!
      ! check if the nodes are in correct numbering
      ! for ray-bi-linear patch intersection see. ramsay
      BiLinearCoeff(:,1,SideID) = GEO%NodeCoords(:,GEO%ElemSideNodeID(1,ilocSide,iElem)) &
                                - GEO%NodeCoords(:,GEO%ElemSideNodeID(2,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(3,ilocSide,iElem)) &
                                - GEO%NodeCoords(:,GEO%ElemSideNodeID(4,ilocSide,iElem))

      BiLinearCoeff(:,2,SideID) =-GEO%NodeCoords(:,GEO%ElemSideNodeID(1,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(2,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(3,ilocSide,iElem)) &
                                - GEO%NodeCoords(:,GEO%ElemSideNodeID(4,ilocSide,iElem))

      BiLinearCoeff(:,3,SideID) =-GEO%NodeCoords(:,GEO%ElemSideNodeID(1,ilocSide,iElem)) &
                                - GEO%NodeCoords(:,GEO%ElemSideNodeID(2,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(3,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(4,ilocSide,iElem))

      BiLinearCoeff(:,4,SideID) = GEO%NodeCoords(:,GEO%ElemSideNodeID(1,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(2,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(3,ilocSide,iElem)) &
                                + GEO%NodeCoords(:,GEO%ElemSideNodeID(4,ilocSide,iElem))
      BiLinearCoeff(:,:,SideID) = 0.25*BiLinearCoeff(:,:,SideID)
      ! compute displacement vector (is displacement form planar plane)
      Displacement = BiLinearCoeff(1,1,SideID)*BiLinearCoeff(1,1,SideID) &
                   + BiLinearCoeff(2,1,SideID)*BiLinearCoeff(2,1,SideID) &
                   + BiLinearCoeff(3,1,SideID)*BiLinearCoeff(3,1,SideID) 
      IF(Displacement.LT.epsilonbilinear)THEN
        SideIsPlanar(SideID)=.TRUE.
        nPlanar=nPlanar+1
      ELSE
        nBilinear=nBilinear+1
      END IF
      SideIsDone(SideID)=.TRUE.
    ELSE
      CYCLE  
    END IF ! SideID
  END DO ! ilocSide
END DO ! iElem

! get number of bc-sides of each element
! nElemBCSides=0
! DO iElem=1,PP_nelems
!   DO ilocSide=1,6
!     SideID=ElemToSide(E2S_SIDE_ID,ilocSide,ElemID) 
!     IF(SideID.LT.nBCSides) nElemBCSides=nElemBCSides+1
!   END DO ! ilocSide
! END DO ! nElemBCSides

SWRITE(UNIT_StdOut,'(132("-"))')
SWRITE(UNIT_StdOut,'(A,I8)') ' Number of planar    surfaces: ', nPlanar
SWRITE(UNIT_StdOut,'(A,I8)') ' Number of bi-linear surfaces: ', nBilinear

ALLOCATE(SideNormVec(1:3,nSides))
SideNormVec=0.
! compute normal vector of planar sides
DO iSide=1,nSides
  IF(SideIsPlanar(SideID))THEN
    SideNormVec(:,iSide)=CROSS(BiLinearCoeff(:,2,iSide),BiLinearCoeff(:,3,iSide))
    nlength=SideNormVec(1,iSide)*SideNormVec(1,iSide) &
           +SideNormVec(2,iSide)*SideNormVec(2,iSide) &
           +SideNormVec(3,iSide)*SideNormVec(3,iSide) 
    SideNormVec(:,iSide) = SideNormVec(:,iSide)/SQRT(nlength)
    SideDistance(iSide)  = DOT_PRODUCT(SideNormVec(:,iSide),BiLinearCoeff(:,4,iSide))
  END IF
END DO ! iSide

DEALLOCATE( SideIsDone)

END SUBROUTINE GetBilinearPlane

FUNCTION CalcBiLinearNormVec(xi,eta,SideID)
!================================================================================================================================
! function to compute the normal vector of a bi-linear surface
!================================================================================================================================
USE MOD_Globals,                              ONLY:CROSS
USE MOD_Particle_Surfaces_Vars,               ONLY:BiLinearCoeff
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!--------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)                        :: xi,eta
INTEGER,INTENT(IN)                     :: SideID
!--------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
REAL,DIMENSION(3)                      :: CalcBiLinearNormVec
!--------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL,DIMENSION(3)                      :: a,b,nVec
REAL                                   :: nlength
!================================================================================================================================

a=xi* BiLinearCoeff(:,1,SideID)+BiLinearCoeff(:,2,SideID)
b=eta*BiLinearCoeff(:,1,SideID)+BiLinearCoeff(:,3,SideID)

nVec=CROSS(a,b)
nlength=nVec(1)*nVec(1)+nVec(2)*nVec(2)+nVec(3)*nVec(3)
nlength=SQRT(nlength)
CalcBiLinearNormVec=nVec/nlength

END FUNCTION CalcBiLinearNormVec

FUNCTION CalcNormVec(xi,eta,QuadID,SideID)
!================================================================================================================================
! function to compute the normal vector of a bi-linear surface
!================================================================================================================================
USE MOD_Globals,                              ONLY:CROSS
USE MOD_Particle_Surfaces_Vars,               ONLY:SuperSampledNodes,NPartCurved
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!--------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)                        :: xi,eta
INTEGER,INTENT(IN)                     :: SideID,QuadID
!--------------------------------------------------------------------------------------------------------------------------------
!OUTPUT VARIABLES
REAL,DIMENSION(3)                      :: CalcNormVec
!--------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL,DIMENSION(3)                      :: a,b,nVec
INTEGER                                :: p,q
REAL                                   :: nlength
!================================================================================================================================

q=(QuadID-1)/NPartCurved ! fortran takes floor of integer devision
p=MOD(QuadID-1,NPartCurved)

!xNodes(:,1)=SuperSampledNodes(1:3,p  ,q  ,SideID)
!xNodes(:,2)=SuperSampledNodes(1:3,p+1,q  ,SideID)
!xNodes(:,3)=SuperSampledNodes(1:3,p+1,q+1,SideID)
!xNodes(:,4)=SuperSampledNodes(1:3,p  ,q+1,SideID)

!b=xi*0.25*( SuperSampledNodes(:,p  ,q  ,SideID)-SuperSampledNodes(:,p+1,q  ,SideID)   &
!           +SuperSampledNodes(:,p+1,q+1,SideID)-SuperSampledNodes(:,p  ,q+1,SideID) ) !&
!

b=xi*0.25*(SuperSampledNodes(:,p  ,q  ,SideID)-SuperSampledNodes(:,p+1,q  ,SideID)  & 
           +SuperSampledNodes(:,p+1,q+1,SideID)-SuperSampledNodes(:,p  ,q+1,SideID) ) &
    +0.25*(-SuperSampledNodes(:,p  ,q  ,SideID)+SuperSampledNodes(:,p+1,q  ,SideID)   &
           +SuperSampledNodes(:,p+1,q+1,SideID)-SuperSampledNodes(:,p  ,q+1,SideID) )

a=eta*0.25*( SuperSampledNodes(:,p  ,q  ,SideID)-SuperSampledNodes(:,p+1,q  ,SideID)   &
            +SuperSampledNodes(:,p+1,q+1,SideID)-SuperSampledNodes(:,p  ,q+1,SideID) ) &
     +0.25*(-SuperSampledNodes(:,p  ,q  ,SideID)-SuperSampledNodes(:,p+1,q  ,SideID)   &
            +SuperSampledNodes(:,p+1,q+1,SideID)-SuperSampledNodes(:,p  ,q+1,SideID) )


nVec=CROSS(a,b)
nlength=nVec(1)*nVec(1)+nVec(2)*nVec(2)+nVec(3)*nVec(3)
nlength=SQRT(nlength)
CalcNormVec=nVec/nlength

END FUNCTION CalcNormVec

SUBROUTINE GetSuperSampledSurface(XCL_NGeo,iElem)
!===================================================================================================================================
! computes the nodes and coeffs for [P][I][C] [A]daptive [S]uper [S]ampled Surfaces [O]perations
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_Preproc
USE MOD_Mesh_Vars,                ONLY:nSides,ElemToSide,SideToElem,NGeo
USE MOD_Particle_Vars,            ONLY:GEO
USE MOD_Particle_Surfaces_Vars,   ONLY:SuperSampledNodes,nPartCurved,Vdm_CLNGeo_EquiNPartCurved
USE MOD_Mesh_Vars,                ONLY:nBCSides,nInnerSides,nMPISides_MINE,nMPISides_YOUR
USE MOD_ChangeBasis,        ONLY:ChangeBasis2D
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
INTEGER,INTENT(IN) :: iElem
REAL,INTENT(IN)    :: XCL_NGeo(3,0:NGeo,0:NGeo,0:NGeo)
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER                           :: lastSideID,flip,SideID
INTEGER                           :: p,q
REAL                              :: tmp(3,0:NPartCurved,0:NPartCurved)  

!===================================================================================================================================

! BCSides, InnerSides and MINE MPISides are filled
lastSideID  = nBCSides+nInnerSides+nMPISides_MINE

! interpolate to xi sides
! xi_minus
SideID=ElemToSide(E2S_SIDE_ID,XI_MINUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,XI_MINUS,iElem).EQ.0) THEN !if flip=0, master side!!
    CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,0,:,:),tmp)
    ! turn into right hand system of side
    DO q=0,NPartCurved
      DO p=0,NPartCurved
        SuperSampledNodes(1:3,p,q,sideID)=tmp(:,q,p)
      END DO !p
    END DO !q
  END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,0,:,:),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF

SideID=ElemToSide(E2S_SIDE_ID,XI_PLUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,XI_PLUS,iElem).EQ.0) THEN !if flip=0, master side!!
    CALL ChangeBasis2D(3,NGeo,nPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,NGeo,:,:),SuperSampledNodes(1:3,:,:,sideID))
  END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,NGeo,:,:),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF

! interpolate to eta sides
SideID=ElemToSide(E2S_SIDE_ID,ETA_MINUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,ETA_MINUS,iElem).EQ.0) THEN !if flip=0, master side!!
    CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,0,:),SuperSampledNodes(1:3,:,:,sideID))
   END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,0,:),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF
  
SideID=ElemToSide(E2S_SIDE_ID,ETA_PLUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,ETA_PLUS,iElem).EQ.0) THEN !if flip=0, master side!!
    CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,NGeo,:),tmp)
    ! turn into right hand system of side
    DO q=0,NPartCurved
      DO p=0,NPartCurved
        SuperSampledNodes(1:3,p,q,sideID)=tmp(:,NPartCurved-p,q)
      END DO !p
    END DO !q
  END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,NGeo,:),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF

! interpolate to zeta sides
SideID=ElemToSide(E2S_SIDE_ID,ZETA_MINUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,ZETA_MINUS,iElem).EQ.0) THEN !if flip=0, master side!!
    CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,:,0),tmp)
    ! turn into right hand system of side
    DO q=0,NPartCurved
      DO p=0,NPartCurved
        SuperSampledNodes(1:3,p,q,sideID)=tmp(:,q,p)
      END DO !p
    END DO !q
  END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,:,0),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF

SideID=ElemToSide(E2S_SIDE_ID,ZETA_PLUS,iElem)
IF(SideID.LE.lastSideID)THEN
  IF(ElemToSide(E2S_FLIP,ZETA_PLUS,iElem).EQ.0) THEN !if flip=0, master side!!
    IF ((sideID.LE.nBCSides))THEN !BC
      CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,:,NGeo),SuperSampledNodes(1:3,:,:,sideID))
    END IF !BC
  END IF !flip=0
ELSE ! no master, here has to come the suff with the slave
  CALL ChangeBasis2D(3,NGeo,NPartCurved,Vdm_CLNGeo_EquiNPartCurved,XCL_NGeo(1:3,:,:,NGeo),tmp)
  flip= SideToElem(S2E_FLIP,SideID)
  SELECT CASE(flip)
    CASE(1) ! slave side, SideID=q,jSide=p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,q,p)
        END DO ! p
      END DO ! q
    CASE(2) ! slave side, SideID=N-p,jSide=q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-p,q)
        END DO ! p
      END DO ! q
    CASE(3) ! slave side, SideID=N-q,jSide=N-p
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,NPartCurved-q,NPartCurved-p)
        END DO ! p
      END DO ! q
    CASE(4) ! slave side, SideID=p,jSide=N-q
      DO q=0,NPartCurved
        DO p=0,NPartCurved
          SuperSampledNodes(:,p,q,SideID)=tmp(:,p,NPartCurved-q)
        END DO ! p
      END DO ! q
  END SELECT
END IF

END SUBROUTINE GetSuperSampledSurface

END MODULE MOD_Particle_Surfaces
