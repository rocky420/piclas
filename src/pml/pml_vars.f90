MODULE MOD_PML_Vars
!===================================================================================================================================
! 
!===================================================================================================================================
! MODULES
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
PUBLIC
SAVE
!-----------------------------------------------------------------------------------------------------------------------------------
! GLOBAL VARIABLES 
!-----------------------------------------------------------------------------------------------------------------------------------
! PML region damping factor
LOGICAL                               :: DoPML                                       ! true/false switch for PML calculation procedures
!REAL,ALLOCATABLE                      :: PMLchiScale(:,:,:,:)                        ! ramping factor for c_corr in PML region from, [1,0] (volume)
REAL,ALLOCATABLE                      :: PMLRamp(:,:,:,:)                            ! ramping function for U(7:8) and Ut(7:8) in PML region , [1,0] (volume)
REAL,ALLOCATABLE                      :: PMLchiScaleFace(:,:,:)                      ! ramping factor for c_corr in PML region from, [1,0] (face)
LOGICAL,ALLOCATABLE                   :: isPMLElem(:)                                ! true if iElem is an element located within the PML region
LOGICAL,ALLOCATABLE                   :: isPMLFace(:)                                ! true if iFace is a Face located wihtin or on the boarder (interface) of the PML region
LOGICAL,ALLOCATABLE                   :: isPMLInterFace(:)                           ! true if iFace is a Face located on the boarder (interface) of the PML region
REAL,ALLOCATABLE                      :: PMLzeta(:,:,:,:,:)                          ! damping factor in xyz
REAL,ALLOCATABLE                      :: PMLzetaGlobal(:,:,:,:,:)                    ! damping factor in xyz: global field for output
INTEGER                               :: PMLzetaShape                                ! shape functions for particle deposition and PML damping coefficient
INTEGER                               :: PMLwriteFields                              ! output zeta field for debug
INTEGER                               :: PMLspread                                   ! if true zeta_x=zeta_y=zeta_z for all PML cells
REAL,DIMENSION(6)                     :: xyzPhysicalMinMax                           ! physical boundary coordinates, outside = PML region
REAL                                  :: PMLzeta0                                    ! damping constant for PML region shift
REAL                                  :: PMLalpha0                                   ! CFS-PML aplha factor for complex frequency shift
LOGICAL                               :: PMLzetaNorm                                 ! normalize zeta_x,y,z in overlapping regions to zeta0
REAL                                  :: PMLRampLength                               ! ramping length in percent (%) of PML region
! mapping variables
INTEGER                               :: nPMLElems,nPMLFaces,nPMLInterFaces          ! number of PML elements and faces (mapping)
INTEGER,ALLOCATABLE                   :: PMLToElem(:),PMLToFace(:),PMLInterToFace(:) ! mapping to total element/face list
INTEGER,ALLOCATABLE                   :: ElemToPML(:),FaceToPML(:),FaceTOPMLInter(:) ! mapping to PML element/face list
! PML auxiliary variables P_t=E & Q_t=B
REAL,ALLOCATABLE                      :: U2(:,:,:,:,:)                               ! U2( P=U2(1:3) and Q=U2(4:6),i,j,k,nPMLElems)
REAL,ALLOCATABLE                      :: U2t(:,:,:,:,:)                              ! U2t(P=U2(1:3) and Q=U2(4:6),i,j,k,nPMLElems)
! CFS-PML auxiliary variables (24xNxNxNxnElemsx8)
! FS and FSt are for divergence correction of E
! FT and FTt are for divergence correction of B
!REAL,ALLOCATABLE,DIMENSION(:,:,:,:,:) :: FP,FQ,FR,FL,FM,FN,FS,FT
!REAL,ALLOCATABLE,DIMENSION(:,:,:,:,:) :: FPt,FQt,FRt,FLt,FMt,FNt,FSt,FTt
REAL,ALLOCATABLE,DIMENSION(:,:,:,:,:) :: PMLzetaEff
REAL,ALLOCATABLE,DIMENSION(:,:,:,:,:) :: PMLalpha
INTEGER                               :: nPMLVars                                    ! is zero or 24 depending
! gradients
!REAL,ALLOCATABLE                      ::dUdx(:,:,:,:,:),dUdy(:,:,:,:,:),dUdz(:,:,:,:,:)
!===================================================================================================================================
END MODULE MOD_PML_Vars
