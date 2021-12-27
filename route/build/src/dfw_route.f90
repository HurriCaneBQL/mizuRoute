MODULE dfw_route_module

USE nrtype
! data types
USE dataTypes,   ONLY: STRFLX            ! fluxes in each reach
USE dataTypes,   ONLY: STRSTA            ! state in each reach
USE dataTypes,   ONLY: RCHTOPO           ! Network topology
USE dataTypes,   ONLY: RCHPRP            ! Reach parameter
USE dataTypes,   ONLY: subbasin_omp      ! mainstem+tributary data strucuture
! global data
USE public_var,  ONLY: iulog             ! i/o logical unit number
USE public_var,  ONLY: realMissing       ! missing value for real number
USE public_var,  ONLY: integerMissing    ! missing value for integer number
! subroutines: general
USE model_finalize, ONLY : handle_err

! privary
implicit none
private

public::dfw_route

CONTAINS

 ! *********************************************************************
 ! subroutine: perform diffusive wave routing through the river network
 ! *********************************************************************
 SUBROUTINE dfw_route(iens,                 & ! input: ensemble index
                      river_basin,          & ! input: river basin information (mainstem, tributary outlet etc.)
                      T0,T1,                & ! input: start and end of the time step
                      ixDesire,             & ! input: reachID to be checked by on-screen pringing
                      NETOPO_in,            & ! input: reach topology data structure
                      RPARAM_in,            & ! input: reach parameter data structure
                      RCHSTA_out,           & ! inout: reach state data structure
                      RCHFLX_out,           & ! inout: reach flux data structure
                      ierr,message,         & ! output: error control
                      ixSubRch)               ! optional input: subset of reach indices to be processed

   implicit none
   ! Input
   integer(i4b),       intent(in)                 :: iEns                 ! ensemble member
   type(subbasin_omp), intent(in),    allocatable :: river_basin(:)       ! river basin information (mainstem, tributary outlet etc.)
   real(dp),           intent(in)                 :: T0,T1                ! start and end of the time step (seconds)
   integer(i4b),       intent(in)                 :: ixDesire             ! index of the reach for verbose output
   type(RCHTOPO),      intent(in),    allocatable :: NETOPO_in(:)         ! River Network topology
   type(RCHPRP),       intent(in),    allocatable :: RPARAM_in(:)         ! River reach parameter
   ! inout
   type(STRSTA),       intent(inout), allocatable :: RCHSTA_out(:,:)      ! reach state data
   type(STRFLX),       intent(inout), allocatable :: RCHFLX_out(:,:)      ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
   ! output variables
   integer(i4b),       intent(out)                :: ierr                 ! error code
   character(*),       intent(out)                :: message              ! error message
   ! input (optional)
   integer(i4b),       intent(in), optional       :: ixSubRch(:)          ! subset of reach indices to be processed
   ! local variables
   character(len=strLen)                          :: cmessage             ! error message for downwind routine
   logical(lgt),                      allocatable :: doRoute(:)           ! logical to indicate which reaches are processed
   integer(i4b)                                   :: LAKEFLAG=0           ! >0 if processing lakes
   integer(i4b)                                   :: nOrder               ! number of stream order
   integer(i4b)                                   :: nTrib                ! number of tributary basins
   integer(i4b)                                   :: nSeg                 ! number of reaches in the network
   integer(i4b)                                   :: iSeg, jSeg           ! loop indices - reach
   integer(i4b)                                   :: iTrib                ! loop indices - branch
   integer(i4b)                                   :: ix                   ! loop indices stream order

   ! initialize error control
   ierr=0; message='dfw_route/'

   ! number of reach check
   if (size(NETOPO_in)/=size(RCHFLX_out(iens,:))) then
    ierr=20; message=trim(message)//'sizes of NETOPO and RCHFLX mismatch'; return
   endif

   nSeg = size(RCHFLX_out(iens,:))

   allocate(doRoute(nSeg), stat=ierr)

   if (present(ixSubRch))then
    doRoute(:)=.false.
    doRoute(ixSubRch) = .true. ! only subset of reaches are on
   else
    doRoute(:)=.true. ! every reach is on
   endif

   nOrder = size(river_basin)

   do ix = 1, nOrder

   ! route diffusive waves through the river network
     nTrib=size(river_basin(ix)%branch)

!$OMP PARALLEL DO schedule(dynamic,1)                   & ! chunk size of 1
!$OMP          private(jSeg, iSeg)                      & ! private for a given thread
!$OMP          private(ierr, cmessage)                  & ! private for a given thread
!$OMP          shared(T0,T1)                            & ! private for a given thread
!$OMP          shared(LAKEFLAG)                         & ! private for a given thread
!$OMP          shared(river_basin)                      & ! data structure shared
!$OMP          shared(doRoute)                          & ! data array shared
!$OMP          shared(NETOPO_in)                        & ! data structure shared
!$OMP          shared(RPARAM_in)                        & ! data structure shared
!$OMP          shared(RCHSTA_out)                       & ! data structure shared
!$OMP          shared(RCHFLX_out)                       & ! data structure shared
!$OMP          shared(ix, iEns, ixDesire)               & ! indices shared
!$OMP          firstprivate(nTrib)
     trib:do iTrib = 1,nTrib
       seg:do iSeg=1,river_basin(ix)%branch(iTrib)%nRch
         jSeg  = river_basin(ix)%branch(iTrib)%segIndex(iSeg)
         if (.not. doRoute(jSeg)) cycle
         call dfw_rch(iEns,jSeg,           & ! input: array indices
                      ixDesire,            & ! input: index of the desired reach
                      T0,T1,               & ! input: start and end of the time step
                      LAKEFLAG,            & ! input: flag if lakes are to be processed
                      NETOPO_in,           & ! input: reach topology data structure
                      RPARAM_in,           & ! input: reach parameter data structure
                      RCHSTA_out,          & ! inout: reach state data structure
                      RCHFLX_out,          & ! inout: reach flux data structure
                      ierr,cmessage)         ! output: error control
         if(ierr/=0) call handle_err(ierr, trim(message)//trim(cmessage))
       end do  seg
     end do trib
!$OMP END PARALLEL DO

   end do

 END SUBROUTINE dfw_route

 ! *********************************************************************
 ! subroutine: perform diffusive wave routing for one segment
 ! *********************************************************************
 SUBROUTINE dfw_rch(iEns, segIndex, & ! input: index of runoff ensemble to be processed
                    ixDesire,       & ! input: reachID to be checked by on-screen pringing
                    T0,T1,          & ! input: start and end of the time step
                    LAKEFLAG,       & ! input: flag if lakes are to be processed
                    NETOPO_in,      & ! input: reach topology data structure
                    RPARAM_in,      & ! input: reach parameter data structure
                    RCHSTA_out,     & ! inout: reach state data structure
                    RCHFLX_out,     & ! inout: reach flux data structure
                    ierr, message)    ! output: error control

 implicit none

 ! Input
 integer(i4b),  intent(in)                 :: iEns              ! runoff ensemble to be routed
 integer(i4b),  intent(in)                 :: segIndex          ! segment where routing is performed
 integer(i4b),  intent(in)                 :: ixDesire          ! index of the reach for verbose output
 real(dp),      intent(in)                 :: T0,T1             ! start and end of the time step (seconds)
 integer(i4b),  intent(in)                 :: LAKEFLAG          ! >0 if processing lakes
 type(RCHTOPO), intent(in),    allocatable :: NETOPO_in(:)      ! River Network topology
 type(RCHPRP),  intent(in),    allocatable :: RPARAM_in(:)      ! River reach parameter
 ! inout
 type(STRSTA),  intent(inout), allocatable :: RCHSTA_out(:,:)   ! reach state data
 type(STRFLX),  intent(inout), allocatable :: RCHFLX_out(:,:)   ! Reach fluxes (ensembles, space [reaches]) for decomposed domains
 ! Output
 integer(i4b),  intent(out)                :: ierr              ! error code
 character(*),  intent(out)                :: message           ! error message
 ! Local variables to
 logical(lgt)                              :: doCheck           ! check details of variables
 logical(lgt)                              :: isHW              ! headwater basin?
 integer(i4b)                              :: nUps              ! number of upstream segment
 integer(i4b)                              :: iUps              ! upstream reach index
 integer(i4b)                              :: iRch_ups          ! index of upstream reach in NETOPO
 real(dp)                                  :: q_upstream        ! total discharge at top of the reach being processed
 character(len=strLen)                     :: cmessage          ! error message from subroutine

 ierr=0; message='dfw_rch/'

 doCheck = .false.
 if(NETOPO_in(segIndex)%REACHIX == ixDesire)then
   doCheck = .true.
 end if

 ! get discharge coming from upstream
 nUps = size(NETOPO_in(segIndex)%UREACHI)
 isHW = .true.
 q_upstream = 0.0_dp
 if (nUps>0) then
   isHW = .false.
   do iUps = 1,nUps
     iRch_ups = NETOPO_in(segIndex)%UREACHI(iUps)      !  index of upstream of segIndex-th reach
     q_upstream = q_upstream + RCHFLX_out(iens, iRch_ups)%REACH_Q
   end do
 endif

 if(doCheck)then
   write(iulog,'(A)') 'CHECK diffusive wave routing'
   if (nUps>0) then
     do iUps = 1,nUps
       iRch_ups = NETOPO_in(segIndex)%UREACHI(iUps)      !  index of upstream of segIndex-th reach
       write(iulog,'(A,X,I12,X,G15.4)') ' UREACHK, uprflux=',NETOPO_in(segIndex)%UREACHK(iUps),RCHFLX_out(iens, iRch_ups)%REACH_Q
     enddo
   end if
   write(iulog,'(A,X,G15.4)') ' RCHFLX_out(iEns,segIndex)%BASIN_QR(1)=',RCHFLX_out(iEns,segIndex)%BASIN_QR(1)
 endif

 ! solve diffusive wave equation
 call diffusive_wave(RPARAM_in(segIndex),         &    ! input: parameter at segIndex reach
                     T0,T1,                       &    ! input: start and end of the time step
                     q_upstream,                  &    ! input: total discharge at top of the reach being processed
                     isHW,                        &    ! input: is this headwater basin?
                     RCHSTA_out(iens,segIndex),   &    ! inout:
                     RCHFLX_out(iens,segIndex),   &    ! inout: updated fluxes at reach
                     doCheck,                     &    ! input: reach index to be examined
                     ierr, cmessage)                    ! output: error control
 if(ierr/=0)then
    write(message, '(A,X,I12,X,A)') trim(message)//'/segment=', NETOPO_in(segIndex)%REACHID, '/'//trim(cmessage)
    return
 endif

 if(doCheck)then
  write(iulog,'(A,X,G15.4)') ' RCHFLX_out(iens,segIndex)%REACH_Q=', RCHFLX_out(iens,segIndex)%REACH_Q
 endif

 END SUBROUTINE dfw_rch


 ! *********************************************************************
 ! subroutine: solve diffuisve wave equation
 ! *********************************************************************
 SUBROUTINE diffusive_wave(rch_param,     & ! input: river parameter data structure
                           T0,T1,         & ! input: start and end of the time step
                           q_upstream,    & ! input: discharge from upstream
                           isHW,          & ! input: is this headwater basin?
                           rstate,        & ! inout: reach state at a reach
                           rflux,         & ! inout: reach flux at a reach
                           doCheck,       & ! input: reach index to be examined
                           ierr,message)
 ! ----------------------------------------------------------------------------------------
 ! Crank-Nicoloson method to solve linearlized diffusive wave equation per reach
 !
 !
 !
 !
 !
 !
 !
 !
 ! state array:

 USE globalData, ONLY : nMolecule   ! number of computational molecule for finite difference (including upstream and downstream boundaries)
 implicit none
 ! Input
 type(RCHPRP), intent(in)        :: rch_param      ! River reach parameter
 real(dp),     intent(in)        :: T0,T1          ! start and end of the time step (seconds)
 real(dp),     intent(in)        :: q_upstream     ! total discharge at top of the reach being processed
 logical(lgt), intent(in)        :: isHW           ! is this headwater basin?
 logical(lgt), intent(in)        :: doCheck        ! reach index to be examined
 ! Input/Output
 type(STRSTA), intent(inout)     :: rstate         ! curent reach states
 type(STRFLX), intent(inout)     :: rflux          ! current Reach fluxes
 ! Output
 integer(i4b), intent(out)       :: ierr           ! error code
 character(*), intent(out)       :: message        ! error message
 ! LOCAL VAIRABLES
 real(dp)                        :: alpha          ! sqrt(slope)(/mannings N* width)
 real(dp)                        :: beta           ! constant, 5/3
 real(dp)                        :: Cd             ! coefficient of discretize diffusive wave equation
 real(dp)                        :: Ca             ! coefficient of discretize diffusive wave equation
 real(dp)                        :: dt             ! interval of time step [sec]
 real(dp)                        :: dx             ! length of segment [m]
 real(dp)                        :: Qbar           ! 3-point average discharge [m3/s]
 real(dp)                        :: Abar           ! 3-point average flow area [m2]
 real(dp)                        :: Vbar           ! 3-point average velocity [m/s]
 real(dp)                        :: ck             ! kinematic wave celerity [m/s]
 real(dp)                        :: dk             ! diffusivity [m2/s]
 real(dp), allocatable           :: diagonal(:,:)  !
 real(dp), allocatable           :: b(:)           !
 real(dp), allocatable           :: Qlocal(:,:)    ! sub-reach discharge at previous time step [m3/s]
 real(dp), allocatable           :: Qprev(:)       ! sub-reach discharge at current time step [m3/s]
 real(dp)                        :: dTsub          ! time inteval for sut time-step [sec]
 real(dp)                        :: wck            ! weight for advection
 real(dp)                        :: wdk            ! weight for diffusion
 integer(i4b)                    :: counter        ! loop counter
 integer(i4b)                    :: ix,it          ! loop index
 integer(i4b)                    :: ntSub          !
 integer(i4b)                    :: Nx             ! number of internal reach segments
 integer(i4b)                    :: Npt            ! number of actual point
 character(len=strLen)           :: fmt1           ! format string
 character(len=strLen)           :: cmessage       ! error message from subroutine

 integer(i4b), parameter  :: maxCounter=1

 ierr=0; message='diffusive_wave/'

 Npt = 4
 ntSub = 1
 wck = 1.0
 wdk = 1.0

 !Nx = nMolecule - 1  ! Nx: number of internal reach segments
 Nx = Npt - 1  ! Nx: number of internal reach segments

 if (.not. isHW) then

   allocate(Qprev(nMolecule), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

   allocate(b(nMolecule), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

   allocate(diagonal(nMolecule,3), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif

   ! initialize previous time step flow
   Qprev(1:nMolecule) = rstate%molecule%Q     ! flow state at previous time step

   ! Get the reach parameters
   ! A = (Q/alpha)**(1/beta)
   ! Q = alpha*A**beta
   alpha = sqrt(rch_param%R_SLOPE)/(rch_param%R_MAN_N*rch_param%R_WIDTH**(2._dp/3._dp))
   beta  = 5._dp/3._dp
   dx = rch_param%RLENGTH/Nx
   dt = T1-T0

   if (doCheck) then
     write(iulog,'(4(A,X,G15.4))') ' length [m] =',rch_param%RLENGTH,'slope [-] =',rch_param%R_SLOPE,'channel width [m] =',rch_param%R_WIDTH,'manning coef =',rch_param%R_MAN_N
   end if

   ! Use average flow from previous time step in computational molecule to compute celerity, diffusivity, matrix coefficient
   Qbar = (Qprev(1)+Qprev(Npt)+q_upstream)/3._dp  ! average discharge [m3/s] from previous time step
   Abar = (abs(Qbar)/alpha)**(1/beta)                   ! average flow area [m2] (from manning equation)
   Vbar = 0._dp
   if (Abar>0._dp) Vbar = Qbar/Abar                     ! average velocity [m/s]
   ck   = beta*Vbar                                     ! kinematic wave celerity [m/s]
   dk   = Qbar/(2*rch_param%R_WIDTH*rch_param%R_SLOPE)  ! diffusivity [m2/s]

   ! create a matrix - current time step (left-hand side of the system of the liear equation )
   Cd = dk*dt/dx**2
   Ca = ck*dt/dx

   ! time-step adjustment so Courant number is less than 1
   dTsub = dt/ntSub

   if (doCheck) then
     write(iulog,'(A,X,I3,A,X,G12.5)') ' No. sub timestep=',nTsub,' sub time-step [sec]=',dTsub
   end if

   allocate(Qlocal(0:1, 1:nMolecule), stat=ierr, errmsg=cmessage)
   if(ierr/=0)then; message=trim(message)//trim(cmessage); return; endif
   Qlocal(0:1,:) = realMissing
   Qlocal(0,1:nMolecule) = Qprev
   Qlocal(1,1)  = q_upstream ! infllow at sub-time step in current time step

   do it = 1, nTsub

     Qbar = (Qlocal(1,1)+Qlocal(0,1)+Qlocal(0,Npt))/3.0 ! 3 point average discharge [m3/s]
     Abar = (abs(Qbar)/alpha)**(1/beta)                            ! flow area [m2] (manning equation)
     Vbar = 0._dp
     if (Abar>0._dp) Vbar = Qbar/Abar                     ! average velocity [m/s]
     ck   = beta*Vbar                                     ! kinematic wave celerity [m/s]
     dk   = Qbar/(2*rch_param%R_WIDTH*rch_param%R_SLOPE)  ! diffusivity [m2/s]

     ! create a matrix - current time step (left-hand side of the system of the liear equation )
     Cd = dk*dTsub/dx**2
     Ca = ck*dTsub/dx

     ! populate diagonal elements
     diagonal(:,2)             = 1._dp
     diagonal(2:nMolecule-1,2) = 2._dp+4._dp*wdk*Cd    ! diagonal

     diagonal(:,1)           = 0._dp
     diagonal(3:nMolecule,1) = wck*Ca-2._dp*wdk*Cd          ! upper

     diagonal(:,3)             = 0._dp
     diagonal(1:nMolecule-2,3) = -wck*Ca-2._dp*wdk*Cd         ! lower

     b(1)  = Qlocal(1,1)                                    ! upstream boundary condition
     b(nMolecule) = Qlocal(0,Npt)                           ! downstream boundary condition (this is actually unknow)

     ! write side of matrix equation
     b(2:nMolecule-1) = (2._dp*(1._dp-wdk)*Cd + (1._dp-wck)*Ca)*Qlocal(0,1:nMolecule-2)  &
                      + (2._dp - 4._dp*(1._dp-wdk)*Cd)*Qlocal(0,2:nMolecule-1)           &
                      + (2._dp*(1._dp-wdk)*Cd - (1._dp-wck)*Ca)*Qlocal(0,3:nMolecule)

     counter = 0

     do while (counter < maxCounter)

       ! solve matrix equation - get updated Qlocal
       call TDMA(nMolecule, diagonal, b, Qlocal(1,:))

       if (doCheck) then
         write(fmt1,'(A,I5,A)') '(A,1X',nMolecule,'(1X,F15.7))'
         write(*,fmt1) ' Q sub_reqch=', (Qlocal(1,ix), ix=1,nMolecule)
       end if

       b(nMolecule) = Qlocal(1,Npt) ! update downstream boundary condition

       counter = counter+1

     end do
     Qlocal(0,:) = Qlocal(1,:)
   end do

   ! store final outflow in data structure
   rflux%REACH_Q = Qlocal(1, Npt) + rflux%BASIN_QR(1)

   if (doCheck) then
     write(iulog,*) 'rflux%REACH_Q= ', rflux%REACH_Q
     write(iulog,*) 'R_WIDTH, R_SLOPE, RLENGTH= ', rch_param%R_WIDTH, rch_param%R_SLOPE, rch_param%RLENGTH
     write(iulog,*) 'Qprev(1:nMolecule)= ', Qprev(1:nMolecule)
     write(iulog,*) 'Qbar, Abar, Vbar, ck, dk= ',Qbar, Abar, Vbar, ck, dk
     write(iulog,*) 'Cd, Ca= ', Cd, Ca
     write(iulog,*) 'diagonal(:,1)= ', diagonal(:,1)
     write(iulog,*) 'diagonal(:,2)= ', diagonal(:,2)
     write(iulog,*) 'diagonal(:,3)= ', diagonal(:,3)
     write(iulog,*) 'b= ', b(1:nMolecule)
   end if

   ! compute volume
   rflux%REACH_VOL(0) = rflux%REACH_VOL(1)
   rflux%REACH_VOL(1) = rflux%REACH_VOL(0) + (Qlocal(1,1) - Qlocal(1,nMolecule-1))*dT

   ! update state
   rstate%molecule%Q = Qlocal(1,:)

 else ! if head-water

   rflux%REACH_Q = rflux%BASIN_QR(1)

   rflux%REACH_VOL(0) = 0._dp
   rflux%REACH_VOL(1) = 0._dp

   rstate%molecule%Q(1:nMolecule) = 0._dp
   rstate%molecule%Q(nMolecule) = rflux%REACH_Q

   if (doCheck) then
     write(iulog,'(A)')            ' This is headwater '
   endif

 endif

 if (doCheck) then
   write(iulog,'(A,X,G12.5)') ' Qout(t) =', rflux%REACH_Q
 endif

 END SUBROUTINE diffusive_wave

 SUBROUTINE TDMA(NX,MAT,b,T)
 ! Solve tridiagonal matrix system of linear equation
 ! NX is the number of unknowns (gridblocks minus boundaries)
 ! Solve system of linear equations, A*T = b where A is tridiagonal matrix
 ! MAT = NX x 3 array holding tri-diagonal portion of A
 ! MAT(NX,1) - uppder diagonals for matrix A
 ! MAT(NX,2) - diagonals for matrix A
 ! MAT(NX,3) - lower diagonals for matrix A
 ! b(NX) - vector of the right hand coefficients b
 ! T(NX) - The solution matrix
 !
 ! example, A
 ! d u 0 0 0
 ! l d u 0 0
 ! 0 l d u 0
 ! 0 0 l d u
 ! 0 0 0 l d
 !
 ! MAT(:,1) = [0, u, u, u, u]
 ! MAT(:,2) = [d, d, d, d, d]
 ! MAT(:,3) = [l, l, l, l, 0]

   IMPLICIT NONE
   ! Input
   integer(i4b),  intent(in)     :: NX     ! number of unknown (= number of matrix size, grid point minus two end points)
   real(dp),      intent(in)     :: MAT(NX,3)
   real(dp),      intent(in)     :: b(NX)
   ! Output
   real(dp),      intent(inout)  :: T(NX)
   ! Local
   integer(i4b)                  :: ix
   real(dp)                      :: U(NX)
   real(dp)                      :: D(NX)
   real(dp)                      :: L(NX)
   real(dp)                      :: b1(NX)
   real(dp)                      :: coef

   U(1:NX) = MAT(1:NX,1)
   D(1:NX) = MAT(1:NX,2)
   L(1:NX) = MAT(1:NX,3)
   b1(1:NX) = b(1:NX)
   do ix = 2, NX
     coef  = L(ix-1)/D(ix-1)
     D(ix) = D(ix)-coef*U(ix)
     b1(ix) = b1(ix)-coef*b1(ix-1)
   end do

   T(NX) = b1(NX)/D(NX) ! Starts the countdown of answers
   do ix = NX-1, 1, -1
       T(ix) = (b1(ix) - U(ix+1)*T(ix+1))/D(ix)
   end do

 END SUBROUTINE TDMA


END MODULE dfw_route_module
