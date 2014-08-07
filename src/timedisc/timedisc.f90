#include "boltzplatz.h"


MODULE MOD_TimeDisc
!===================================================================================================================================
! Module for the GTS Temporal discretization  
!===================================================================================================================================
! MODULES
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
PRIVATE
!-----------------------------------------------------------------------------------------------------------------------------------
INTERFACE InitTimeDisc
  MODULE PROCEDURE InitTimeDisc
END INTERFACE

INTERFACE TimeDisc
  MODULE PROCEDURE TimeDisc
END INTERFACE

INTERFACE FinalizeTimeDisc
  MODULE PROCEDURE FinalizeTimeDisc
END INTERFACE

PUBLIC :: InitTimeDisc,FinalizeTimeDisc
PUBLIC :: TimeDisc
!===================================================================================================================================

CONTAINS

SUBROUTINE InitTimeDisc()
!===================================================================================================================================
! Get information for end time and max time steps from ini file
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_ReadInTools,          ONLY:GetReal,GetInt
USE MOD_TimeDisc_Vars,        ONLY:CFLScale,TEnd,dt,TimeDiscInitIsDone
#if (PP_TimeDiscMethod>=100 && PP_TimeDiscMethod<200) 
USE MOD_TimeDisc_Vars,        ONLY:epsTilde_LinearSolver,eps_LinearSolver,eps2_LinearSolver,maxIter_LinearSolver
#endif /*PP_TimeDiscMethod>=100*/
USE MOD_TimeDisc_Vars,        ONLY:IterDisplayStep,DoDisplayIter
USE MOD_PreProc
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!===================================================================================================================================
IF(TimeDiscInitIsDone)THEN
   SWRITE(*,*) "InitTimeDisc already called."
   RETURN
END IF
SWRITE(UNIT_StdOut,'(132("-"))')
SWRITE(UNIT_stdOut,'(A)') ' INIT TIMEDISC...'

! Read the normalized CFL number
CFLScale = GETREAL('CFLScale')
CALL fillCFL_DFL()

! read in requested IterDisplayStep (i.e. how often the message "iter: etc" is displayed)
DoDisplayIter=.FALSE.
IterDisplayStep = GETINT('IterDisplayStep','1')
IF(IterDisplayStep.GE.1) DoDisplayIter=.TRUE.

#if (PP_TimeDiscMethod>=100 && PP_TimeDiscMethod<200) 
eps_LinearSolver = GETREAL('eps_LinearSolver')
epsTilde_LinearSolver = eps_LinearSolver
eps2_LinearSolver = eps_LinearSolver *eps_LinearSolver 
maxIter_LinearSolver = GETINT('maxIter_LinearSolver')
#endif

! Set timestep to a large number
dt=HUGE(1.)
#if (PP_TimeDiscMethod==1)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: LSERK3-3 '
#elif (PP_TimeDiscMethod==2)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: LSERK4-5 '
#elif (PP_TimeDiscMethod==3)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: TAYLOR'
#elif (PP_TimeDiscMethod==4)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: DSMC-Only'
#elif (PP_TimeDiscMethod==5)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: RK4-Field, Euler-Explicit-Particles'
#elif (PP_TimeDiscMethod==6)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: LSERK4-14 '
#elif (PP_TimeDiscMethod==42)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: DSMC Reservoir and Debug'
#elif (PP_TimeDiscMethod==100)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: Euler Implicit'
#elif (PP_TimeDiscMethod==101)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: ESDIRK4 Implicit'
#elif (PP_TimeDiscMethod==200)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: Euler Static Explicit'
#elif (PP_TimeDiscMethod==201)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: Euler Static Explicit with adaptive TimeStep'
#elif (PP_TimeDiscMethod==1000)
  SWRITE(UNIT_stdOut,'(A)') ' Method of time integration: LD-Only'
# endif
TimediscInitIsDone = .TRUE.
SWRITE(UNIT_stdOut,'(A)')' INIT TIMEDISC DONE!'
SWRITE(UNIT_StdOut,'(132("-"))')
END SUBROUTINE InitTimeDisc



SUBROUTINE TimeDisc()
!===================================================================================================================================
! GTS Temporal discretization 
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_PreProc
USE MOD_PoyntingInt,           ONLY: CalcPoyntingIntegral
USE MOD_TimeDisc_Vars,         ONLY: TEnd,dt,tAnalyze,iter,IterDisplayStep,DoDisplayIter
USE MOD_Restart_Vars,          ONLY: DoRestart,RestartTime
USE MOD_CalcTimeStep,          ONLY: CalcTimeStep
USE MOD_Analyze,               ONLY: CalcError,PerformeAnalyze
USE MOD_Analyze_Vars,          ONLY: Analyze_dt,CalcPoyntingInt
USE MOD_Particle_Analyze,      ONLY: AnalyzeParticles
USE MOD_Particle_Analyze_Vars, ONLY: DoAnalyze, PartAnalyzeStep
USE MOD_Output,                ONLY: Visualize
USE MOD_HDF5_output,           ONLY: WriteStateToHDF5
USE MOD_Mesh_Vars,             ONLY: MeshFile,nGlobalElems
USE MOD_DG_Vars,               ONLY: U
USE MOD_PML,                   ONLY: TransformPMLVars,BacktransformPMLVars
USE MOD_PML_Vars,              ONLY: DoPML
USE MOD_Filter,                ONLY: Filter
USE MOD_RecordPoints_Vars,     ONLY: RP_inUse,RP_onProc
USE MOD_RecordPoints,          ONLY: RecordPoints,WriteRPToHDF5
#ifdef PARTICLES
USE MOD_PICDepo,               ONLY: Deposition, DepositionMPF
USE MOD_PICDepo_Vars,          ONLY: DepositionType
USE MOD_Particle_Output,       ONLY: Visualize_Particles
USE MOD_PARTICLE_Vars,         ONLY: ManualTimeStep, Time, dt_max_particles, dt_maxwell, NextTimeStepAdjustmentIter, &
                                     dt_adapt_maxwell,useManualTimestep, DelayTime, usevMPF
USE MOD_PARTICLE_Vars,         ONLY: PDM, PartState, MaxwellIterNum, GEO, Pt
USE MOD_PARTICLE_Vars,         ONLY : doParticleMerge, enableParticleMerge, vMPFMergeParticleIter
USE MOD_ReadInTools
USE MOD_DSMC_Vars,             ONLY: useDSMC, realtime,nOutput, Iter_macvalout
USE MOD_Equation_Vars,         ONLY: c,c_corr
USE MOD_LD_Vars,               ONLY: useLD
#ifdef MPI
USE MOD_part_boundary,         ONLY: ParticleBoundary, Communicate_PIC
#endif
#endif /*PARTICLES*/
#ifdef PP_POIS
USE MOD_Equation,              ONLY: EvalGradient
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL                         :: t,tFuture, vMax, vMaxx, vMaxy, vMaxz
REAL                         :: dt_Min, tEndDiff, tAnalyzeDiff, dt_temp
INTEGER(KIND=8)              :: iter_loc
REAL                         :: CalcTimeStart,CalcTimeEnd
INTEGER                      :: TimeArray(8)              ! Array for system time
INTEGER                      :: MaximumIterNum
!===================================================================================================================================
! init
SWRITE(UNIT_StdOut,'(132("-"))')
#ifdef PARTICLES
iter_macvalout=0
nOutput = 1
IF(.NOT.DoRestart)THEN
  realtime=0.
  time=0.
ELSE
  realtime=RestartTime
  Time = RestartTime
END IF
#endif /*PARTICLES*/

IF(.NOT.DoRestart)THEN
  t=0.
  SWRITE(UNIT_StdOut,*)'INITIAL PROJECTION:'
ELSE
  t=RestartTime
  SWRITE(UNIT_StdOut,*)'REWRITING SOLUTION:'
END IF
tAnalyze=MIN(t+Analyze_dt,tEnd)

! write number of grid cells and dofs only once per computation
SWRITE(UNIT_stdOut,'(A13,ES16.7)')'#GridCells : ',REAL(nGlobalElems)
SWRITE(UNIT_stdOut,'(A13,ES16.7)')'#DOFs      : ',REAL(nGlobalElems*(PP_N+1)**3)
SWRITE(UNIT_stdOut,'(A13,ES16.7)')'#Procs     : ',REAL(nProcessors)

! Determine next analyze time, since it will be written into output file
tFuture=MIN(t+Analyze_dt,tEnd)
!Evaluate Gradients to get Potential in case of Restart and Poisson Calc
#ifdef PP_POIS
IF(DoRestart) CALL EvalGradient()
#endif
! Write the state at time=0, i.e. the initial condition
CALL WriteStateToHDF5(TRIM(MeshFile),t,tFuture)

! init of analyzation and write file header
! Determine the initial error
CALL CalcError(t)
! first analyze Particles and DG solution (write zero state)
CALL AnalyzeParticles(t) 
IF (CalcPoyntingInt) CALL CalcPoyntingIntegral(t,doProlong=.TRUE.)
!CALL Visualize_Particles(t)

! No computation needed if tEnd=tStart!
IF(t.EQ.tEnd)RETURN

#ifdef PARTICLES
#ifdef MPI
IF (DepositionType.EQ."shape_function") THEN
  CALL ParticleBoundary()
  CALL Communicate_PIC()
END IF
#endif /*MPI*/

! For tEnd != tStart we have to advance the solution in time
IF(useManualTimeStep)THEN
  ! particle time step is given externally and not calculated through the solver
  dt_Min=ManualTimeStep
#if (PP_TimeDiscMethod==200)
  dt_max_particles = ManualTimeStep
  dt_maxwell = CALCTIMESTEP()
  NextTimeStepAdjustmentIter = 0
  MaxwellIterNum = MAX(GEO%xmaxglob-GEO%xminglob,GEO%ymaxglob-GEO%yminglob,GEO%zmaxglob-GEO%zminglob) &
                 / (c * dt_maxwell)
  IF (MaxwellIterNum*dt_maxwell.GT.dt_max_particles) THEN
    WRITE(*,*) 'WARNING: Time of Maxwell Solver is greater then particle time step!'
  END IF
  IF(MPIroot)THEN
    print*, 'IterNum for MaxwellSolver: ', MaxwellIterNum
    print*, 'Particle TimeStep: ', dt_max_particles  
    print*, 'Maxwell TimeStep: ', dt_maxwell
  END IF
#endif
ELSE ! .NO. ManualTimeStep
#endif /*PARTICLES*/
  ! time step is calculated by the solver
  ! first Maxwell time step for explicit LSRK
  dt_Min=CALCTIMESTEP()
  ! calculate time step for sub-cycling of divergence correction
  ! automatic particle time step of quasi-stationary time integration is not implemented
#ifdef PARTICLES
#if (PP_TimeDiscMethod==200)
  ! this will not work if particles have velocity of zero
  SWRITE(UNIT_StdOut, '(A)')'ERROR: with Static computations, a maximum delta t (=ManualTimeStep) needs to be given'
  STOP
#endif
END IF ! useManualTimestep

#if (PP_TimeDiscMethod==201)
dt_maxwell = CALCTIMESTEP()
MaximumIterNum = MAX(GEO%xmaxglob-GEO%xminglob,GEO%ymaxglob-GEO%yminglob,GEO%zmaxglob-GEO%zminglob) &
               / (c * dt_maxwell)
IF(MPIroot)THEN
  print*, 'MaxIterNum for MaxwellSolver: ', MaximumIterNum
  print*, 'Maxwell TimeStep: ', dt_maxwell
END IF
dt_temp = 1E-8
#endif
#endif /*PARTICLES*/

SWRITE(UNIT_StdOut,'(132("-"))')
SWRITE(UNIT_StdOut,'(A,ES16.7)')'Initial Timestep  : ', dt_Min
! using sub-cycling requires an addional time step
SWRITE(UNIT_StdOut,*)'CALCULATION RUNNING...'
CalcTimeStart=BOLTZPLATZTIME()
iter=0
iter_loc=0

! fill recordpoints buffer (first iteration)
IF(RP_onProc) CALL RecordPoints(iter,t,forceSampling=.FALSE.) 


!-----------------------------------------------------------------------------------------------------------------------------------
! iterations starting up from here
!-----------------------------------------------------------------------------------------------------------------------------------
DO !iter_t=0,MaxIter 

#if (PP_TimeDiscMethod==201)
!  IF (vMax.EQ.0) THEN
!    dt_max_particles = dt_maxwell
!  ELSE
!    dt_max_particles = 3.8*dt_maxwell*c/(vMax)!the 3.8 is a factor that lead to a timestep of 2/3*min_celllength
!                      ! this factor should be adjusted
!  END IF
  IF (iter.LE.MaximumIterNum) THEN
      dt_max_particles = dt_maxwell ! initial evolution of field with maxwellts
  ELSE
    DO 
      vMaxx = MAXVAL(ABS(PDM%ParticleInside(1:PDM%ParticleVecLength) &
            * (PartState(1:PDM%ParticleVecLength, 4) + dt_temp*Pt(1:PDM%ParticleVecLength,1))))
      vMaxy = MAXVAL(ABS(PDM%ParticleInside(1:PDM%ParticleVecLength) &
            * (PartState(1:PDM%ParticleVecLength, 5) + dt_temp*Pt(1:PDM%ParticleVecLength,2))))
      vMaxz = MAXVAL(ABS(PDM%ParticleInside(1:PDM%ParticleVecLength) &
            * (PartState(1:PDM%ParticleVecLength, 6) + dt_temp*Pt(1:PDM%ParticleVecLength,3))))
      vMax = MAX(vMaxx,vMaxy,vMaxz,1.0) 
#ifdef MPI
     CALL MPI_ALLREDUCE(MPI_IN_PLACE,vMax,1,MPI_DOUBLE_PRECISION,MPI_MAX,MPI_COMM_WORLD,iError)
#endif /*MPI*/

      dt_max_particles = 3.8*dt_maxwell*c/(vMax)
      dt_temp = (dt_max_particles+dt_temp)/2
      IF((dt_temp.GE.dt_max_particles*0.95).AND.(dt_temp.LE.dt_max_particles*1.05)) EXIT
    END DO
  END IF
  dt_Min = dt_max_particles
  MaxwellIterNum = dt_max_particles / dt_maxwell 
  IF (MaxwellIterNum.GT.MaximumIterNum) MaxwellIterNum = MaximumIterNum
  IF(MPIroot)THEN
    SWRITE(UNIT_StdOut,'(132("!"))')
    print*, 'New IterNum for MaxwellSolver: ', MaxwellIterNum 
    print*, 'New Particle TimeStep: ', dt_max_particles
  END IF
#endif

#ifdef PARTICLES
IF(enableParticleMerge) THEN
  IF ((iter.GT.0).AND.(MOD(iter,vMPFMergeParticleIter).EQ.0)) doParticleMerge=.true.
END IF
#endif /*PARTICLES*/

  tAnalyzeDiff=tAnalyze-t    ! time to next analysis, put in extra variable so number does not change due to numerical errors
  tEndDiff=tEnd-t            ! dito for end time
  dt=MIN(MIN(dt_Min,tAnalyzeDiff),MIN(dt_Min,tEndDiff))
  IF (tAnalyzeDiff-dt.LT.dt/100.0) dt = tAnalyzeDiff
  IF (tEndDiff-dt.LT.dt/100.0) dt = tEndDiff


! Perform Timestep using a global time stepping routine, attention: only RK3 has time dependent BC
#if (PP_TimeDiscMethod==1)
  CALL TimeStepByLSERK(t,iter,tEndDiff)
#elif (PP_TimeDiscMethod==2)
  CALL TimeStepByLSERK(t,iter,tEndDiff)
#elif (PP_TimeDiscMethod==3)
  CALL TimeStepByTAYLOR(t)
#elif (PP_TimeDiscMethod==4)
  CALL TimeStep_DSMC(t)
#elif (PP_TimeDiscMethod==5)
  CALL TimeStepByRK4EulerExpl(t)
#elif (PP_TimeDiscMethod==6)
  CALL TimeStepByLSERK(t,iter,tEndDiff)
#elif (PP_TimeDiscMethod==42)
  CALL TimeStep_DSMC_Debug(t) ! Reservoir and Debug
#elif (PP_TimeDiscMethod==100)
  CALL TimeStepByEulerImplicit(t) ! O1 Euler Implicit
#elif (PP_TimeDiscMethod==101)
  CALL TimeStepByESDIRK4(t) ! O4 Implicit Runge Kutta
#elif (PP_TimeDiscMethod==200)
  CALL TimeStepByEulerStaticExp(t) ! O1 Euler Static Explicit
#elif (PP_TimeDiscMethod==201)
  CALL TimeStepByEulerStaticExpAdapTS(t) ! O1 Euler Static Explicit with adaptive TimeStep
#elif (PP_TimeDiscMethod==1000)
  CALL TimeStep_LD(t)
#endif
  iter=iter+1
  iter_loc=iter_loc+1
  t=t+dt
#ifdef PARTICLES
  realtime=realtime+dt
#endif /*PARTICLES*/
  IF(DoDisplayIter)THEN
    IF(MOD(iter,IterDisplayStep).EQ.0) THEN
       SWRITE(*,*) "iter:", iter,"t:",t
    END IF
  END IF
#if (PP_TimeDiscMethod!=1) &&  (PP_TimeDiscMethod!=2) && (PP_TimeDiscMethod!=6)
  ! calling the analyze routines
  CALL PerformeAnalyze(t,iter,tendDiff,force=.FALSE.)
#endif
  ! output of state file
  IF ((dt.EQ.tAnalyzeDiff).OR.(dt.EQ.tEndDiff)) THEN   ! timestep is equal to time to analyze or end
    CalcTimeEnd=BOLTZPLATZTIME()
    IF(MPIroot)THEN
      ! Get calculation time per DOF
      CalcTimeEnd=(CalcTimeEnd-CalcTimeStart)*nProcessors/(nGlobalElems*(PP_N+1)**3*iter_loc)
      CALL DATE_AND_TIME(values=TimeArray) ! get System time
      WRITE(UNIT_StdOut,'(132("-"))')
      WRITE(UNIT_stdOut,'(A,I2.2,A1,I2.2,A1,I4.4,A1,I2.2,A1,I2.2,A1,I2.2)') &
        ' Sys date  :    ',timeArray(3),'.',timeArray(2),'.',timeArray(1),' ',timeArray(5),':',timeArray(6),':',timeArray(7)
      WRITE(UNIT_stdOut,'(A,ES12.5,A)')' CALCULATION TIME PER TSTEP/DOF: [',CalcTimeEnd,' sec ]'
      WRITE(UNIT_StdOut,'(A,ES16.7)')' Timestep  : ',dt_Min
      WRITE(UNIT_stdOut,'(A,ES16.7)')'#Timesteps : ',REAL(iter)
    END IF !MPIroot
    ! Analyze for output
    CALL PerformeAnalyze(t,iter,tenddiff,force=.TRUE.)
    ! future time
    tFuture=t+Analyze_dt
    ! Write state to file
    IF(DoPML) CALL BacktransformPMLVars()
    CALL WriteStateToHDF5(TRIM(MeshFile),t,tFuture)
    IF(DoPML) CALL TransformPMLVars()
    ! Write recordpoints data to hdf5
    IF(RP_inUse) CALL WriteRPtoHDF5(iter,t)
    iter_loc=0
    CalcTimeStart=BOLTZPLATZTIME()
    tAnalyze=tAnalyze+Analyze_dt
    IF (tAnalyze > tEnd) tAnalyze = tEnd
  ENDIF   
  IF(t.GE.tEnd) THEN  ! done, worst case: one additional time step
    EXIT
  END IF
END DO ! iter_t
!CALL FinalizeAnalyze
END SUBROUTINE TimeDisc

#if (PP_TimeDiscMethod==1) || (PP_TimeDiscMethod==2) || (PP_TimeDiscMethod==6)
SUBROUTINE TimeStepByLSERK(t,iter,tEndDiff)
!===================================================================================================================================
! Hesthaven book, page 64
! Low-Storage Runge-Kutta integration of degree 4 with 5 stages.
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
!===================================================================================================================================
! MODULES
USE MOD_PreProc
USE MOD_Analyze,          ONLY: PerformeAnalyze
USE MOD_TimeDisc_Vars,    ONLY: dt
USE MOD_TimeDisc_Vars,    ONLY: RK4_a,RK4_b,RK4_c,nRKStages
USE MOD_DG_Vars,          ONLY: U,Ut
USE MOD_PML_Vars,         ONLY: PMLzeta,U2,U2t,nPMLElems,DoPML
USE MOD_PML,              ONLY: PMLTimeDerivative,CalcPMLSource
USE MOD_Filter,           ONLY: Filter
USE MOD_Equation,         ONLY: DivCleaningDamping
USE MOD_Equation,         ONLY: CalcSource
!USE MOD_DG,               ONLY: DGTimeDerivative_WoSource_weakForm
USE MOD_DG,               ONLY: DGTimeDerivative_weakForm
#ifdef PP_POIS
USE MOD_Equation,         ONLY: DivCleaningDamping_Pois,EvalGradient
USE MOD_DG,               ONLY: DGTimeDerivative_weakForm_Pois
USE MOD_Equation_Vars,    ONLY: Phi,Phit,nTotalPhi
#endif
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY: Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY: InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY: PIC
USE MOD_Particle_Vars,    ONLY: PartState, Pt, Pt_temp, LastPartPos, DelayTime, Time, PEM, PDM, usevMPF
USE MOD_part_RHS,         ONLY: CalcPartRHS
USE MOD_part_boundary,    ONLY: ParticleBoundary
USE MOD_Particle_Tracking,ONLY: ParticleTracking
USE MOD_part_emission,    ONLY: ParticleInserting
USE MOD_DSMC,             ONLY: DSMC_main
USE MOD_DSMC_Vars,        ONLY: useDSMC, DSMC_RHS, DSMC
#ifdef MPI
USE MOD_part_boundary,    ONLY: ParticleBoundary, Communicate_PIC
#else /*No MPI*/
USE MOD_part_boundary,    ONLY: ParticleBoundary
#endif /*MPI*/
USE MOD_part_tools,       ONLY: UpdateNextFreePosition
#endif /*PARTICLES*/
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)               :: tendDiff
REAL,INTENT(INOUT)            :: t
INTEGER(KIND=8),INTENT(INOUT) :: iter
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL                          :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
REAL                          :: U2t_temp(1:6,0:PP_N,0:PP_N,0:PP_N,1:nPMLElems) ! temporal variable for U2t
REAL                          :: tStage,b_dt(1:nRKStages)
INTEGER                       :: rk
#ifdef PP_POIS
REAL                          :: Phit_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
#endif
real:: tstart,tend,t1,t2
!===================================================================================================================================

t1=0.
t2=0.

! RK coefficients
DO rk=1,nRKStages
  b_dt(rk)=RK4_b(rk)*dt
END DO

#ifdef PARTICLES
Time=t
IF (t.GE.DelayTime) THEN
  CALL ParticleInserting()
! forces on particle
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF

IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  IF (usevMPF) THEN 
    CALL DepositionMPF()
  ELSE 
    CALL Deposition()
  END IF
  !CALL CalcDepositedCharge()
END IF
#endif /*PARTICLES*/

! field solver
CALL DGTimeDerivative_weakForm(t,t,0)
IF(DoPML) THEN
  CALL CalcPMLSource()
  CALL PMLTimeDerivative()
END IF
CALL DivCleaningDamping()

#ifdef PP_POIS
! Potential
CALL DGTimeDerivative_weakForm_Pois(t,t,0)
CALL DivCleaningDamping_Pois()
#endif

! calling the analyze routines
CALL PerformeAnalyze(t,iter,tendDiff,force=.FALSE.)

! first RK step
! EM field
Ut_temp = Ut 
U = U + Ut*b_dt(1)
!PML auxiliary variables
IF(DoPML) THEN
  U2t_temp = U2t
  U2 = U2 + U2t*b_dt(1)
END IF

#ifdef PP_POIS
Phit_temp = Phit 
Phi = Phi + Phit*b_dt(1)
CALL EvalGradient()
#endif

#ifdef PARTICLES
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN
  Pt_temp(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,4) 
  Pt_temp(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,5) 
  Pt_temp(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,6) 
  Pt_temp(1:PDM%ParticleVecLength,4) = Pt(1:PDM%ParticleVecLength,1) 
  Pt_temp(1:PDM%ParticleVecLength,5) = Pt(1:PDM%ParticleVecLength,2) 
  Pt_temp(1:PDM%ParticleVecLength,6) = Pt(1:PDM%ParticleVecLength,3)
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) &
                                       + PartState(1:PDM%ParticleVecLength,4)*b_dt(1)
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) &
                                       + PartState(1:PDM%ParticleVecLength,5)*b_dt(1)
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) &
                                       + PartState(1:PDM%ParticleVecLength,6)*b_dt(1)
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                       + Pt(1:PDM%ParticleVecLength,1)*b_dt(1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                       + Pt(1:PDM%ParticleVecLength,2)*b_dt(1)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                       + Pt(1:PDM%ParticleVecLength,3)*b_dt(1)
END IF
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
!CALL CPU_TIME(tStart)
!CALL ParticleBoundary()
!CALL CPU_TIME(tend)
!t1=tend-tstart

!CALL CPU_TIME(tStart)
CALL ParticleTracking()
!jCALL CPU_TIME(tend)
!jt2=tend-tstart

#ifdef MPI
  CALL Communicate_PIC()
  !CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
  !CALL Filter(U)
END IF
#endif /*PARTICLES*/

DO rk=2,nRKStages
  tStage=t+dt*RK4_c(rk)
#ifdef PARTICLES
  ! deposition  
  IF (t.GE.DelayTime) THEN 
    IF (usevMPF) THEN 
      CALL DepositionMPF()
    ELSE 
      CALL Deposition()
    END IF
  END IF
  ! particle RHS
  IF (t.GE.DelayTime) THEN
    CALL InterpolateFieldToParticle()
    CALL CalcPartRHS()
  END IF
#endif /*PARTICLES*/

  ! field solver
  CALL DGTimeDerivative_weakForm(t,tStage,0)
  IF(DoPML) THEN
    CALL CalcPMLSource()
    CALL PMLTimeDerivative()
  END IF
  CALL DivCleaningDamping()

#ifdef PP_POIS
  CALL DGTimeDerivative_weakForm_Pois(t,tStage,0)
  CALL DivCleaningDamping_Pois()
#endif

  ! performe RK steps
  ! field step
  Ut_temp = Ut - Ut_temp*RK4_a(rk)
  U = U + Ut_temp*b_dt(rk)
  !PML auxiliary variables
  IF(DoPML)THEN
    U2t_temp = U2t - U2t_temp*RK4_a(rk)
    U2 = U2 + U2t_temp*b_dt(rk)
  END IF

#ifdef PP_POIS
  Phit_temp = Phit - Phit_temp*RK4_a(rk)
  Phi = Phi + Phit_temp*b_dt(rk)
  CALL EvalGradient()
#endif

#ifdef PARTICLES
  ! particle step
  IF (t.GE.DelayTime) THEN
    LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
    LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
    LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
    PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
    Pt_temp(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,4) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,1)
    Pt_temp(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,5) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,2)
    Pt_temp(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,6) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,3)
    Pt_temp(1:PDM%ParticleVecLength,4) = Pt(1:PDM%ParticleVecLength,1) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,4)
    Pt_temp(1:PDM%ParticleVecLength,5) = Pt(1:PDM%ParticleVecLength,2) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,5)
    Pt_temp(1:PDM%ParticleVecLength,6) = Pt(1:PDM%ParticleVecLength,3) &
                             - RK4_a(rk) * Pt_temp(1:PDM%ParticleVecLength,6)
    PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) &
                                       + Pt_temp(1:PDM%ParticleVecLength,1)*b_dt(rk)
    PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) &
                                       + Pt_temp(1:PDM%ParticleVecLength,2)*b_dt(rk)
    PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) &
                                       + Pt_temp(1:PDM%ParticleVecLength,3)*b_dt(rk)
    PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                       + Pt_temp(1:PDM%ParticleVecLength,4)*b_dt(rk)
    PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                       + Pt_temp(1:PDM%ParticleVecLength,5)*b_dt(rk)
    PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                       + Pt_temp(1:PDM%ParticleVecLength,6)*b_dt(rk)
    ! particle tracking
    !CALL ParticleBoundary()
    CALL ParticleTracking()
#ifdef MPI
      CALL Communicate_PIC()
!    CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
!CALL CPU_TIME(tStart)
 !CALL ParticleBoundary()
!CALL CPU_TIME(tend)
!t1=t1+tend-tstart
!
!CALL CPU_TIME(tStart)
!!  CALL ParticleTracking()
!CALL CPU_TIME(tend)
!t2=t2+tend-tstart

  END IF
#endif /*PARTICLES*/

END DO

#ifdef PARTICLES
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  CALL UpdateNextFreePosition()
END IF

!print*,'time',t1,t2

IF (useDSMC) THEN
  IF (t.GE.DelayTime) THEN
    CALL DSMC_main()
    PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,1)
    PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,2)
    PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,3)
  END IF
END IF
#endif /*PARTICLES*/

END SUBROUTINE TimeStepByLSERK
#endif

#if (PP_TimeDiscMethod==3) 
SUBROUTINE TimeStepByTAYLOR(t)
!===================================================================================================================================
! TAYLOR DG
! time order = N+1
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
!===================================================================================================================================
! MODULES
USE MOD_DG_Vars,ONLY:U,Ut,nTotalU
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY:dt
USE MOD_DG,ONLY:DGTimeDerivative_weakForm
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)  :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL             :: U_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
REAL             :: Factor
INTEGER          :: tIndex,i
!===================================================================================================================================
Factor = dt
#ifdef OPTIMIZED
DO i=1,nTotalU
  U_temp(i,0,0,0,1) = U(i,0,0,0,1)
END DO
#else
U_temp=U
#endif OPTIMIZED

DO tIndex=0,PP_N
 CALL DGTimeDerivative_weakForm(t,t,tIndex)
#ifdef OPTIMIZED
DO i=1,nTotalU
  U(i,0,0,0,1) = Ut(i,0,0,0,1)
  U_temp(i,0,0,0,1) = U_temp(i,0,0,0,1) + Factor*Ut(i,0,0,0,1)
END DO
#else
 U=Ut
 U_temp = U_temp + Factor*Ut
#endif
 Factor = Factor*dt/REAL(tIndex+2)
END DO ! tIndex

#ifdef OPTIMIZED
DO i=1,nTotalU
  U(i,0,0,0,1) = U_temp(i,0,0,0,1)
END DO
#else
U=U_temp
#endif
END SUBROUTINE TimeStepByTAYLOR
#endif

#if (PP_TimeDiscMethod==4)
SUBROUTINE TimeStep_DSMC(t)
!===================================================================================================================================
! Hesthaven book, page 64
! Low-Storage Runge-Kutta integration of degree 4 with 5 stages.
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
!===================================================================================================================================
! MODULES
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt
USE MOD_Filter,ONLY:Filter
#ifdef PARTICLES
USE MOD_Particle_Vars,    ONLY : PartState, LastPartPos, Time, PDM,PEM
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_tools,       ONLY : UpdateNextFreePosition
USE MOD_part_emission,    ONLY : ParticleInserting
#endif
#ifdef MPI
USE MOD_part_boundary,    ONLY : Communicate_PIC
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL                  :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
REAL                  :: tStage,b_dt(1:5)
INTEGER               :: i,rk, iPart
!===================================================================================================================================
Time = t

  CALL ParticleInserting()
  LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
  LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
  LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
  PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) &
                                         + PartState(1:PDM%ParticleVecLength,4) * dt
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) &
                                         + PartState(1:PDM%ParticleVecLength,5) * dt
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) &
                                         + PartState(1:PDM%ParticleVecLength,6) * dt

  CALL ParticleBoundary()
#ifdef MPI
  CALL Communicate_PIC()
#endif
  CALL UpdateNextFreePosition()
  CALL DSMC_main()

END SUBROUTINE TimeStep_DSMC
#endif


#if (PP_TimeDiscMethod==5)
SUBROUTINE TimeStepByRK4EulerExpl(t)
!===================================================================================================================================
! Hesthaven book, page 64
! Low-Storage Runge-Kutta integration of degree 4 with 5 stages.
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
!===================================================================================================================================
! MODULES
USE MOD_DG_Vars,ONLY: U,Ut,nTotalU
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt
USE MOD_TimeDisc_Vars,ONLY: RK4_a,RK4_b,RK4_c
USE MOD_DG,ONLY:DGTimeDerivative_weakForm
USE MOD_Filter,ONLY:Filter
USE MOD_Equation,ONLY:DivCleaningDamping
#ifdef PP_POIS
USE MOD_Equation,ONLY:DivCleaningDamping_Pois,EvalGradient
USE MOD_DG,ONLY:DGTimeDerivative_weakForm_Pois
USE MOD_Equation_Vars,ONLY:Phi,Phit,nTotalPhi
#endif
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY : Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY : InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY : PIC
USE MOD_Particle_Vars,    ONLY : PartState, Pt, LastPartPos, DelayTime, Time, PEM, PDM, usevMPF, doParticleMerge
USE MOD_part_RHS,         ONLY : CalcPartRHS
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_emission,    ONLY : ParticleInserting
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
USE MOD_part_MPFtools,    ONLY : StartParticleMerge
#ifdef MPI
USE MOD_part_boundary,    ONLY : ParticleBoundary, Communicate_PIC
#else
USE MOD_part_boundary,    ONLY : ParticleBoundary
#endif
USE MOD_PIC_Analyze,ONLY: CalcDepositedCharge
USE MOD_part_tools,     ONLY : UpdateNextFreePosition
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL                  :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
#ifdef PP_POIS
REAL                  :: Phit_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
#endif
REAL                  :: tStage,b_dt(1:5)
INTEGER               :: i,rk
!===================================================================================================================================
Time = t
IF (t.GE.DelayTime) CALL ParticleInserting()
!CALL UpdateNextFreePosition()
DO rk=1,5
  b_dt(rk)=RK4_b(rk)*dt   ! TBD: put in initiation (with maxwell we are linear!!!)
END DO

!IF(t.EQ.0) CALL Deposition()
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  IF (usevMPF) THEN 
    CALL DepositionMPF()
  ELSE 
    CALL Deposition()
  END IF
  !CALL CalcDepositedCharge()
END IF

IF (t.GE.DelayTime) THEN
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN ! Euler-Explicit only for Particles 
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) + dt * PartState(1:PDM%ParticleVecLength,4) 
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) + dt * PartState(1:PDM%ParticleVecLength,5) 
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) + dt * PartState(1:PDM%ParticleVecLength,6) 
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) + dt * Pt(1:PDM%ParticleVecLength,1) 
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) + dt * Pt(1:PDM%ParticleVecLength,2) 
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) + dt * Pt(1:PDM%ParticleVecLength,3) 
END IF
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  CALL ParticleBoundary()
#ifdef MPI
  CALL Communicate_PIC()
!CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
END IF

! EM field
CALL DGTimeDerivative_weakForm(t,t,0)
CALL DivCleaningDamping()
Ut_temp = Ut 
U = U + Ut*b_dt(1)

DO rk=2,5
  tStage=t+dt*RK4_c(rk)
  ! field RHS
  CALL DGTimeDerivative_weakForm(t,tStage,0)
  CALL DivCleaningDamping()
  ! field step
  Ut_temp = Ut - Ut_temp*RK4_a(rk)
  U = U + Ut_temp*b_dt(rk)
END DO

#ifdef PP_POIS
! EM field
CALL DGTimeDerivative_weakForm_Pois(t,t,0)

CALL DivCleaningDamping_Pois()
Phit_temp = Phit 
Phi = Phi + Phit*b_dt(1)

DO rk=2,5
  tStage=t+dt*RK4_c(rk)
  ! field RHS
  CALL DGTimeDerivative_weakForm_Pois(t,tStage,0)
  CALL DivCleaningDamping_Pois()
  ! field step
  Phit_temp = Phit - Phit_temp*RK4_a(rk)
  Phi = Phi + Phit_temp*b_dt(rk)
END DO

  CALL EvalGradient()
#endif
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  CALL UpdateNextFreePosition()
END IF
IF (doParticleMerge) THEN
  CALL StartParticleMerge()
  CALL UpdateNextFreePosition()
END IF

IF (useDSMC) THEN
  IF (t.GE.DelayTime) THEN
    CALL DSMC_main()
    PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,1)
    PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,2)
    PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                           + DSMC_RHS(1:PDM%ParticleVecLength,3)
  END IF
END IF
END SUBROUTINE TimeStepByRK4EulerExpl
#endif

#if (PP_TimeDiscMethod==42)
SUBROUTINE TimeStep_DSMC_Debug(t)
!===================================================================================================================================
! Hesthaven book, page 64
! Low-Storage Runge-Kutta integration of degree 4 with 5 stages.
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
!===================================================================================================================================
! MODULES
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt
USE MOD_Filter,ONLY:Filter
#ifdef PARTICLES
USE MOD_Particle_Vars,    ONLY : PartState, LastPartPos, Time, PDM,PEM
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_tools,       ONLY : UpdateNextFreePosition
USE MOD_part_emission,    ONLY : ParticleInserting
#endif
#ifdef MPI
USE MOD_part_boundary,    ONLY : Communicate_PIC
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL                  :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
REAL                  :: tStage,b_dt(1:5)
INTEGER               :: i,rk, iPart, help
!===================================================================================================================================
Time = t

IF (DSMC%ReservoirSimu) THEN ! fix grid should be defined for reservoir simu
  CALL UpdateNextFreePosition()
  CALL DSMC_main()
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
ELSE
  CALL ParticleInserting()
  LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
  LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
  LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
  ! bugfix if more than 2.x mio (2000001) particle per process
  ! tested with 64bit Ubuntu 12.04 backports
  DO i = 1, PDM%ParticleVecLength
    PEM%lastElement(i)=PEM%Element(i)
  END DO
!   PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) &
                                         + PartState(1:PDM%ParticleVecLength,4) * dt
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) &
                                         + PartState(1:PDM%ParticleVecLength,5) * dt
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) &
                                         + PartState(1:PDM%ParticleVecLength,6) * dt
  CALL ParticleBoundary()
#ifdef MPI
  CALL Communicate_PIC()
#endif
  CALL UpdateNextFreePosition()
  CALL DSMC_main()
END IF

END SUBROUTINE TimeStep_DSMC_Debug
#endif

#if (PP_TimeDiscMethod==100) 
SUBROUTINE TimeStepByEulerImplicit(t)
!===================================================================================================================================
! Euler Implicit method:
! U^n+1 = U^n + dt*R(U^n+1)
! (I -dt*R)*U^n+1 = U^n
! Solve Linear System 
!===================================================================================================================================
! MODULES
USE MOD_TimeDisc_Vars,ONLY:dt
USE MOD_DG_Vars                 ,ONLY:U,Ut
USE MOD_DG                      ,ONLY:DGTimeDerivative_weakForm
USE MOD_LinearSolver,     ONLY : LinearSolver
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY : Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY : InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY : PIC
USE MOD_Particle_Vars,    ONLY : PartState, Pt, LastPartPos, DelayTime, Time, PEM, PDM, usevMPF
USE MOD_part_RHS,         ONLY : CalcPartRHS
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_emission,    ONLY : ParticleInserting
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
#ifdef MPI
USE MOD_part_boundary,    ONLY : ParticleBoundary, Communicate_PIC
#else
USE MOD_part_boundary,    ONLY : ParticleBoundary
#endif
USE MOD_PIC_Analyze,ONLY: CalcDepositedCharge
USE MOD_part_tools,     ONLY : UpdateNextFreePosition
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)    :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!===================================================================================================================================
Time = t
IF (t.GE.DelayTime) CALL ParticleInserting()

IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  IF (usevMPF) THEN 
    CALL DepositionMPF()
  ELSE 
    CALL Deposition()
  END IF
  !CALL CalcDepositedCharge()
END IF

IF (t.GE.DelayTime) THEN
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN ! Euler-Explicit only for Particles 
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) + dt * PartState(1:PDM%ParticleVecLength,4) 
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) + dt * PartState(1:PDM%ParticleVecLength,5) 
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) + dt * PartState(1:PDM%ParticleVecLength,6) 
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) + dt * Pt(1:PDM%ParticleVecLength,1) 
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) + dt * Pt(1:PDM%ParticleVecLength,2) 
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) + dt * Pt(1:PDM%ParticleVecLength,3) 
END IF
CALL ParticleBoundary()
#ifdef MPI
CALL Communicate_PIC()
!CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
! EM field
CALL LinearSolver(t,dt)
CALL DivCleaningDamping()
CALL UpdateNextFreePosition()
IF (useDSMC) THEN
  CALL DSMC_main()
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
END IF

END SUBROUTINE TimeStepByEulerImplicit
#endif /*PP_TimeDiscMethod==100*/

#if (PP_TimeDiscMethod==101) 
SUBROUTINE TimeStepByESDIRK4(t)
!===================================================================================================================================
! RK4 IMPLICIT
! time order = N+1
! This procedure takes the current time t, the time step dt and the solution at
! the current time U(t) and returns the solution at the next time level.
! Butcher Tableau taken from Bijl, Carpenter, Vatsa, Kennedy - doi:10.1006/jcph.2002.7059
!===================================================================================================================================
! MODULES
USE MOD_Globals
USE MOD_DG_Vars                 ,ONLY:U,Ut
USE MOD_DG                      ,ONLY:DGTimeDerivative_weakForm
USE MOD_PreProc
USE MOD_TimeDisc_Vars
USE MOD_Equation,ONLY:DivCleaningDamping
USE MOD_Equation,      ONLY: CalcSource
USE MOD_LinearSolver,  ONLY : LinearSolver
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY : Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY : InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY : PIC
USE MOD_Particle_Vars,    ONLY : PartState, Pt, LastPartPos, DelayTime, Time, PEM, PDM, usevMPF
USE MOD_part_RHS,         ONLY : CalcPartRHS
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_emission,    ONLY : ParticleInserting
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
#ifdef MPI
USE MOD_part_boundary,    ONLY : ParticleBoundary, Communicate_PIC
#else
USE MOD_part_boundary,    ONLY : ParticleBoundary
#endif
USE MOD_PIC_Analyze,ONLY: CalcDepositedCharge
USE MOD_part_tools,     ONLY : UpdateNextFreePosition
#endif

! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)    :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
REAL     :: Un(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)

REAL     :: K1(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
REAL     :: K2(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
REAL     :: K3(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
REAL     :: K4(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
REAL     :: K5(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)

REAL     :: tStage

Time = t
IF (t.GE.DelayTime) CALL ParticleInserting()

IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
    IF (usevMPF) THEN 
      CALL DepositionMPF()
    ELSE 
      CALL Deposition()
    END IF
  !CALL CalcDepositedCharge()
END IF

IF (t.GE.DelayTime) THEN
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN ! Euler-Explicit only for Particles 
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) + dt * PartState(1:PDM%ParticleVecLength,4) 
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) + dt * PartState(1:PDM%ParticleVecLength,5) 
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) + dt * PartState(1:PDM%ParticleVecLength,6) 
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) + dt * Pt(1:PDM%ParticleVecLength,1) 
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) + dt * Pt(1:PDM%ParticleVecLength,2) 
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) + dt * Pt(1:PDM%ParticleVecLength,3) 
END IF
CALL ParticleBoundary()
#ifdef MPI
CALL Communicate_PIC()
!CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
! EM field
!===================================================================================================================================
! Save state at t(n)
Un = U
! ----------------------------------------------------------------------------------------------------------------------------------
tStage = t
CALL DGTimeDerivative_weakForm(t, tStage, 0)
CALL DivCleaningDamping()
K1  = Ut
! ----------------------------------------------------------------------------------------------------------------------------------
tStage = t + 0.5 * dt
! Fixed part of the RHS
U = Un + dt*0.25*K1
CALL LinearSolver(tStage,0.25*dt)
CALL DGTimeDerivative_weakForm(t, tStage, 0)
CALL DivCleaningDamping()
K2=Ut
! ----------------------------------------------------------------------------------------------------------------------------------
tStage = t + 83./250. * dt
! Fixed part of the RHS
U = Un + dt*(8611./62500.*K1 - 1743./31250.*K2)
CALL LinearSolver(tStage,0.25*dt)
CALL DGTimeDerivative_weakForm(t, tStage, 0)
CALL DivCleaningDamping()
K3=Ut
! ----------------------------------------------------------------------------------------------------------------------------------
tStage = t + 31./50. * dt
U = Un + dt*( 5012029./34652500.*K1 - 654441./2922500.*K2 + 174375./388108.*K3)
CALL LinearSolver(tStage,0.25*dt)
CALL DGTimeDerivative_weakForm(t, tStage, 0)
CALL DivCleaningDamping()
K4=Ut
! ----------------------------------------------------------------------------------------------------------------------------------
tStage = t + 17./20. * dt
! Fixed part of the RHS
U = Un + dt*(15267082809./155376265600.*K1 - 71443401./120774400.*K2 + 730878875./902184768.*K3 + 2285395./8070912.*K4)
CALL LinearSolver(tStage,0.25*dt)
CALL DGTimeDerivative_weakForm(t, tStage, 0)
CALL DivCleaningDamping()
K5=Ut
!-----------------------------------------------------------------------------------------------------------------------------------
tStage = t + dt
! Fixed part of the RHS
U = Un + dt*(82889./524892.*K1 + 15625./83664.*K3 + 69875./102672.*K4 - 2260./8211.*K5)
CALL LinearSolver(tStage,0.25*dt)
CALL UpdateNextFreePosition()
IF (useDSMC) THEN
  CALL DSMC_main()
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
END IF

CALL DivCleaningDamping()
END SUBROUTINE TimeStepByESDIRK4
#endif /*PP_TimeDiscMethod==101*/

#if (PP_TimeDiscMethod==200)
SUBROUTINE TimeStepByEulerStaticExp(t)
!===================================================================================================================================
! Static (using 4 or 8 variables, depending on compiled equation system (maxwell or electrostatic):
! Field is propagated until steady, then particle is moved
!===================================================================================================================================
! MODULES
USE MOD_DG_Vars,ONLY: U,Ut,nTotalU
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt
USE MOD_TimeDisc_Vars,ONLY: RK4_a,RK4_b,RK4_c
USE MOD_DG,ONLY:DGTimeDerivative_weakForm
USE MOD_Filter,ONLY:Filter
USE MOD_Equation,ONLY:DivCleaningDamping
USE MOD_Globals
#ifdef PP_POIS
USE MOD_Equation,ONLY:DivCleaningDamping_Pois,EvalGradient
USE MOD_DG,ONLY:DGTimeDerivative_weakForm_Pois
USE MOD_Equation_Vars,ONLY:Phi,Phit,nTotalPhi
#endif
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY : Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY : InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY : PIC
USE MOD_Particle_Vars,    ONLY : PartState, Pt, LastPartPos, DelayTime, Time, PEM, PDM, dt_maxwell, MaxwellIterNum, usevMPF
USE MOD_part_RHS,         ONLY : CalcPartRHS
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_emission,    ONLY : ParticleInserting
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
#ifdef MPI
USE MOD_part_boundary,    ONLY : ParticleBoundary, Communicate_PIC
#else
USE MOD_part_boundary,    ONLY : ParticleBoundary
#endif
USE MOD_PIC_Analyze,ONLY: CalcDepositedCharge
USE MOD_part_tools,     ONLY : UpdateNextFreePosition
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER               :: i,rk, iLoop
REAL                  :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
#ifdef PP_POIS
REAL                  :: Phit_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
#endif
REAL                  :: b_dt(1:5)
REAL                  :: dt_save, tStage, t_rk
!===================================================================================================================================
Time = t
IF (t.GE.DelayTime) CALL ParticleInserting()

IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
    IF (usevMPF) THEN 
      CALL DepositionMPF()
    ELSE 
      CALL Deposition()
    END IF
  !CALL CalcDepositedCharge()
END IF
IF (t.GE.DelayTime) THEN
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN ! Euler-Explicit only for Particles 
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) + dt * PartState(1:PDM%ParticleVecLength,4) 
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) + dt * PartState(1:PDM%ParticleVecLength,5) 
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) + dt * PartState(1:PDM%ParticleVecLength,6) 
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) + dt * Pt(1:PDM%ParticleVecLength,1) 
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) + dt * Pt(1:PDM%ParticleVecLength,2) 
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) + dt * Pt(1:PDM%ParticleVecLength,3) 
END IF
CALL ParticleBoundary()
#ifdef MPI
CALL Communicate_PIC()
!CALL UpdateNextFreePosition() ! only required for parallel communication
#endif
! EM field

dt_save = dt  !quick hack
t_rk = t
dt = dt_maxwell

DO rk=1,5
  b_dt(rk)=RK4_b(rk)*dt   ! TBD: put in initiation (with maxwell we are linear!!!)
END DO
DO iLoop = 1, MaxwellIterNum
  ! EM field

  CALL DGTimeDerivative_weakForm(t_rk,t_rk,0)
  CALL DivCleaningDamping()
  Ut_temp = Ut 
  U = U + Ut*b_dt(1)
 
  DO rk=2,5
    tStage=t_rk+dt*RK4_c(rk)
    ! field RHS
    CALL DGTimeDerivative_weakForm(t_rk,tStage,0)
    CALL DivCleaningDamping()
    ! field step
    Ut_temp = Ut - Ut_temp*RK4_a(rk)
    U = U + Ut_temp*b_dt(rk)
  END DO
#ifdef PP_POIS
  ! Potential field
  CALL DGTimeDerivative_weakForm_Pois(t_rk,t_rk,0)

  CALL DivCleaningDamping_Pois()
  Phit_temp = Phit
  Phi = Phi + Phit*b_dt(1)

  DO rk=2,5
    tStage=t_rk+dt*RK4_c(rk)
    ! field RHS
    CALL DGTimeDerivative_weakForm_Pois(t_rk,tStage,0)
    CALL DivCleaningDamping_Pois()
    ! field step
    Phit_temp = Phit - Phit_temp*RK4_a(rk)
    Phi = Phi + Phit_temp*b_dt(rk)
  END DO
#endif
  t_rk = t_rk + dt
END DO
dt = dt_save
#ifdef PP_POIS
  CALL EvalGradient()
#endif
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  CALL UpdateNextFreePosition()
END IF
IF (useDSMC) THEN
  IF (t.GE.DelayTime) THEN
    CALL DSMC_main()
    PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
    PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
    PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
  END IF
END IF
END SUBROUTINE TimeStepByEulerStaticExp
#endif

#if (PP_TimeDiscMethod==201)
SUBROUTINE TimeStepByEulerStaticExpAdapTS(t)
!===================================================================================================================================
! Static (using 4 or 8 variables, depending on compiled equation system (maxwell or electrostatic):
! Field is propagated until steady or a particle velo dependent adaptive time, then particle is moved
!===================================================================================================================================
! MODULES
USE MOD_DG_Vars,ONLY: U,Ut,nTotalU
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt
USE MOD_TimeDisc_Vars,ONLY: RK4_a,RK4_b,RK4_c
USE MOD_DG,ONLY:DGTimeDerivative_weakForm
USE MOD_Filter,ONLY:Filter
USE MOD_Equation,ONLY:DivCleaningDamping
USE MOD_Globals
#ifdef PP_POIS
USE MOD_Equation,ONLY:DivCleaningDamping_Pois,EvalGradient
USE MOD_DG,ONLY:DGTimeDerivative_weakForm_Pois
USE MOD_Equation_Vars,ONLY:Phi,Phit,nTotalPhi
#endif
#ifdef PARTICLES
USE MOD_PICDepo,          ONLY : Deposition, DepositionMPF
USE MOD_PICInterpolation, ONLY : InterpolateFieldToParticle
USE MOD_PIC_Vars,         ONLY : PIC
USE MOD_Particle_Vars,    ONLY : PartState, Pt, LastPartPos, DelayTime, Time, PEM, PDM, dt_maxwell, MaxwellIterNum, usevMPF
USE MOD_part_RHS,         ONLY : CalcPartRHS
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_emission,    ONLY : ParticleInserting
USE MOD_DSMC,             ONLY : DSMC_main
USE MOD_DSMC_Vars,        ONLY : useDSMC, DSMC_RHS, DSMC
#ifdef MPI
USE MOD_part_boundary,    ONLY : ParticleBoundary, Communicate_PIC
#else
USE MOD_part_boundary,    ONLY : ParticleBoundary
#endif
USE MOD_PIC_Analyze,ONLY: CalcDepositedCharge
USE MOD_part_tools,     ONLY : UpdateNextFreePosition
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
INTEGER               :: i,rk, iLoop
REAL                  :: Ut_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems) ! temporal variable for Ut
#ifdef PP_POIS
REAL                  :: Phit_temp(1:PP_nVar,0:PP_N,0:PP_N,0:PP_N,1:PP_nElems)
#endif
REAL                  :: b_dt(1:5)
REAL                  :: dt_save, tStage, t_rk
!===================================================================================================================================
Time = t
IF (t.GE.DelayTime) CALL ParticleInserting()

IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
    IF (usevMPF) THEN 
      CALL DepositionMPF()
    ELSE 
      CALL Deposition()
    END IF
  !CALL CalcDepositedCharge()
END IF

IF (t.GE.DelayTime) THEN
  CALL InterpolateFieldToParticle()
  CALL CalcPartRHS()
END IF
! particles
LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)
IF (t.GE.DelayTime) THEN ! Euler-Explicit only for Particles 
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) + dt * PartState(1:PDM%ParticleVecLength,4) 
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) + dt * PartState(1:PDM%ParticleVecLength,5) 
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) + dt * PartState(1:PDM%ParticleVecLength,6) 
  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) + dt * Pt(1:PDM%ParticleVecLength,1) 
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) + dt * Pt(1:PDM%ParticleVecLength,2) 
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) + dt * Pt(1:PDM%ParticleVecLength,3) 
END IF
CALL ParticleBoundary()
#ifdef MPI
CALL Communicate_PIC()
!CALL UpdateNextFreePosition() ! only required for parallel communication
#endif

! EM field

dt_save = dt  !quick hack
t_rk = t
dt = dt_maxwell

DO rk=1,5
  b_dt(rk)=RK4_b(rk)*dt   ! TBD: put in initiation (with maxwell we are linear!!!)
END DO

DO iLoop = 1, MaxwellIterNum
  ! EM field

  CALL DGTimeDerivative_weakForm(t_rk,t_rk,0)
  CALL DivCleaningDamping()
  Ut_temp = Ut 
  U = U + Ut*b_dt(1)
 
  DO rk=2,5
    tStage=t_rk+dt*RK4_c(rk)
    ! field RHS
    CALL DGTimeDerivative_weakForm(t_rk,tStage,0)
    CALL DivCleaningDamping()
    ! field step
    Ut_temp = Ut - Ut_temp*RK4_a(rk)
    U = U + Ut_temp*b_dt(rk)
  END DO
#ifdef PP_POIS
  ! Potential field
  CALL DGTimeDerivative_weakForm_Pois(t_rk,t_rk,0)

  CALL DivCleaningDamping_Pois()
  Phit_temp = Phit
  Phi = Phi + Phit*b_dt(1)

  DO rk=2,5
    tStage=t_rk+dt*RK4_c(rk)
    ! field RHS
    CALL DGTimeDerivative_weakForm_Pois(t_rk,tStage,0)
    CALL DivCleaningDamping_Pois()
    ! field step
    Phit_temp = Phit - Phit_temp*RK4_a(rk)
    Phi = Phi + Phit_temp*b_dt(rk)
  END DO
#endif

  t_rk = t_rk + dt
END DO
dt = dt_save

#ifdef PP_POIS
  CALL EvalGradient()
#endif
IF ((t.GE.DelayTime).OR.(t.EQ.0)) THEN
  CALL UpdateNextFreePosition()
END IF
IF (useDSMC) THEN
  IF (t.GE.DelayTime) THEN
    CALL DSMC_main()
    PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,1)
    PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,2)
    PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + DSMC_RHS(1:PDM%ParticleVecLength,3)
  END IF
END IF
END SUBROUTINE TimeStepByEulerStaticExpAdapTS
#endif

#if (PP_TimeDiscMethod==1000)
SUBROUTINE TimeStep_LD(t)
!===================================================================================================================================
! Low Diffusion Method (Mirza 2013)
!===================================================================================================================================
! MODULES
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY: dt, iter
USE MOD_Filter,ONLY:Filter
#ifdef PARTICLES
USE MOD_Particle_Vars,    ONLY : PartState, LastPartPos, Time, PDM,PEM 
USE MOD_LD_Vars,          ONLY : LD_RHS
USE MOD_LD,               ONLY : LD_main
USE MOD_part_boundary,    ONLY : ParticleBoundary
USE MOD_part_tools,       ONLY : UpdateNextFreePosition
USE MOD_part_emission,    ONLY : ParticleInserting
#endif
#ifdef MPI
USE MOD_part_boundary,    ONLY : Communicate_PIC
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
REAL,INTENT(IN)       :: t
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES

!===================================================================================================================================
  Time = t
  CALL LD_main()
  LastPartPos(1:PDM%ParticleVecLength,1)=PartState(1:PDM%ParticleVecLength,1)
  LastPartPos(1:PDM%ParticleVecLength,2)=PartState(1:PDM%ParticleVecLength,2)
  LastPartPos(1:PDM%ParticleVecLength,3)=PartState(1:PDM%ParticleVecLength,3)
  PEM%lastElement(1:PDM%ParticleVecLength)=PEM%Element(1:PDM%ParticleVecLength)

  PartState(1:PDM%ParticleVecLength,4) = PartState(1:PDM%ParticleVecLength,4) &
                                         + LD_RHS(1:PDM%ParticleVecLength,1)
  PartState(1:PDM%ParticleVecLength,5) = PartState(1:PDM%ParticleVecLength,5) &
                                         + LD_RHS(1:PDM%ParticleVecLength,2)
  PartState(1:PDM%ParticleVecLength,6) = PartState(1:PDM%ParticleVecLength,6) &
                                         + LD_RHS(1:PDM%ParticleVecLength,3)
  PartState(1:PDM%ParticleVecLength,1) = PartState(1:PDM%ParticleVecLength,1) &
                                         + PartState(1:PDM%ParticleVecLength,4) * dt
  PartState(1:PDM%ParticleVecLength,2) = PartState(1:PDM%ParticleVecLength,2) &
                                         + PartState(1:PDM%ParticleVecLength,5) * dt
  PartState(1:PDM%ParticleVecLength,3) = PartState(1:PDM%ParticleVecLength,3) &
                                         + PartState(1:PDM%ParticleVecLength,6) * dt
  CALL ParticleBoundary()
#ifdef MPI
  CALL Communicate_PIC()
#endif
  CALL ParticleInserting()
  CALL UpdateNextFreePosition()

END SUBROUTINE TimeStep_LD
#endif

SUBROUTINE FillCFL_DFL()
!===================================================================================================================================
! scaling of the CFL number, from paper GASSNER, KOPRIVA, "A comparision of the Gauss and Gauss-Lobatto
! Discontinuous Galerkin Spectral Element Method for Wave Propagation Problems" . For N=1-10, 
! input CFLscale can now be 1. and will be scaled adequately depending on PP_N, NodeType and TimeDisc method 
! DFLscale dependance not implemented jet.
!===================================================================================================================================

! MODULES
USE MOD_Globals
USE MOD_PreProc
USE MOD_TimeDisc_Vars,ONLY:CFLScale
#if (PP_TimeDiscMethod==2) || (PP_TimeDiscMethod==5) || (PP_TimeDiscMethod==200) || (PP_TimeDiscMethod==201)
USE MOD_TimeDisc_Vars,ONLY:CFLScaleAlpha
#endif
#if (PP_TimeDiscMethod==6) || (PP_TimeDiscMethod==1)
USE MOD_TimeDisc_Vars,ONLY:CFLScaleAlpha
#endif
! IMPLICIT VARIABLE HANDLING
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! INPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!===================================================================================================================================
! CFL in DG depends on the polynomial degree

#if (PP_TimeDiscMethod==3)
#  if (PP_NodeType==1)
  !Gauss  Taylor DG Timeorder=SpaceOrder
  CFLscale=CFLscale*0.55*(2*PP_N+1)/(PP_N+1)
#  elif (PP_NodeType==2)
  !Gauss-Lobatto  Taylor DG Timeorder=SpaceOrder, scales with N+1
  CFLscale=CFLscale*(2*PP_N+1)/(PP_N+1)
#  endif /*PP_NodeType*/
#endif /*PP_TimeDiscMethod*/

#if (PP_TimeDiscMethod==2) || (PP_TimeDiscMethod==5) || (PP_TimeDiscMethod==200)||(PP_TimeDiscMethod==201)||(PP_TimeDiscMethod==1)
IF(PP_N.GT.10) CALL abort(&
  __STAMP__,&
  'Polynomial degree is to high!',PP_N,999.)
CFLScale=CFLScale*CFLScaleAlpha(PP_N)
#endif
#if (PP_TimeDiscMethod==6)
IF(PP_N.GT.15) CALL abort(&
  __STAMP__,&
  'Polynomial degree is to high!',PP_N,999.)
CFLScale=CFLScale*CFLScaleAlpha(PP_N)
#endif
!scale with 2N+1
CFLScale = CFLScale/(2.*PP_N+1.)
SWRITE(UNIT_stdOut,'(A,ES16.7)') '   CFL:',CFLScale
END SUBROUTINE fillCFL_DFL



SUBROUTINE FinalizeTimeDisc()
!===================================================================================================================================
! Finalizes variables necessary for analyse subroutines
!===================================================================================================================================
! MODULES
USE MOD_TimeDisc_Vars,ONLY:TimeDiscInitIsDone
! IMPLICIT VARIABLE HANDLINGDGInitIsDone
IMPLICIT NONE
!-----------------------------------------------------------------------------------------------------------------------------------
! OUTPUT VARIABLES
!-----------------------------------------------------------------------------------------------------------------------------------
! LOCAL VARIABLES
!===================================================================================================================================
TimeDiscInitIsDone = .FALSE.
END SUBROUTINE FinalizeTimeDisc


END MODULE MOD_TimeDisc
