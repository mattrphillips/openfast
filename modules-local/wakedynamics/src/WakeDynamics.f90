!**********************************************************************************************************************************
! LICENSING
! Copyright (C) 2015-2016  National Renewable Energy Laboratory
!
!    This file is part of WakeDynamics.
!
! Licensed under the Apache License, Version 2.0 (the "License");
! you may not use this file except in compliance with the License.
! You may obtain a copy of the License at
!
!     http://www.apache.org/licenses/LICENSE-2.0
!
! Unless required by applicable law or agreed to in writing, software
! distributed under the License is distributed on an "AS IS" BASIS,
! WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
! See the License for the specific language governing permissions and
! limitations under the License.
!
!**********************************************************************************************************************************
! File last committed: $Date$
! (File) Revision #: $Rev$
! URL: $HeadURL$
!**********************************************************************************************************************************
!> WakeDynamics is a time-domain module for modeling wake dynamics of one or more horizontal-axis wind turbines.
module WakeDynamics
    
   use NWTC_Library
   use WakeDynamics_Types
     
   implicit none

   private
   
   type(ProgDesc), parameter  :: WD_Ver = ProgDesc( 'WakeDynamics', '', '' )
   character(*),   parameter  :: WD_Nickname = 'WD'      

   ! ..... Public Subroutines ...................................................................................................

   public :: WD_Init                           ! Initialization routine
   public :: WD_End                            ! Ending routine (includes clean up)
   public :: WD_UpdateStates                   ! Loose coupling routine for solving for constraint states, integrating
                                               !   continuous states, and updating discrete states
   public :: WD_CalcOutput                     ! Routine for computing outputs
   public :: WD_CalcConstrStateResidual        ! Tight coupling routine for returning the constraint state residual
   
   
      ! Unit testing routines
   public :: WD_TEST_Init_BadData    
   public :: WD_TEST_Init_GoodData    
   public :: WD_TEST_UpdateStates
  
   contains  

function  WD_Interp ( yVal, xArr, yArr )
   real(ReKi)                     :: WD_Interp
   real(ReKi),      intent(in   ) :: yVal
   real(ReKi),      intent(in   ) :: xArr(:) 
   real(ReKi),      intent(in   ) :: yArr(:)
   
   integer(IntKi)  :: i, nPts
   real(ReKi)      :: y1,y2,x1,x2,dy
   
   
   nPts = size(xArr)
   WD_Interp = 0.0_ReKi
   y2 = yArr(nPts) - yVal
   x2 = xArr(nPts)
   do i=nPts-1,1,-1
      y1 = yArr(i) - yVal 
      x1 = xArr(i)
      if( nint( sign(1.0_ReKi, y1) ) /= nint( sign(1.0_ReKi, y2) ) ) then
                 
         dy = y2-y1
         if (EqualRealNos(dy,0.0_ReKi) ) then
            WD_Interp =  x2
         else
            WD_Interp = (x2-x1)*(yVal-y1)/(dy) + x1  
         end if
         exit
         
      end if
      
      y2 = y1
      x2 = x1
   end do
   
end function WD_Interp
!----------------------------------------------------------------------------------------------------------------------------------   
!> This function sets the nacelle-yaw-related directional term for the yaw correction deflection calculations
!!   
function GetYawCorrection(yawErr, xhat_disk, dx, p, errStat, errMsg)
   real(ReKi), dimension(3) :: GetYawCorrection
   real(ReKi),                    intent(in   )  :: yawErr           !< Nacelle-yaw error at the wake planes
   real(ReKi),                    intent(in   )  :: xhat_disk(3)     !< Orientation of rotor centerline, normal to disk
   real(ReKi),                    intent(in   )  :: dx               !< Dot_product(xhat_plane,V_plane)*DT
   type(WD_ParameterType),        intent(in   )  :: p                !< Parameters
   integer(IntKi),                intent(  out)  :: errStat          !< Error status of the operation
   character(*),                  intent(  out)  :: errMsg           !< Error message if errStat /= ErrID_None
   
   real(ReKi) :: xydisk(3),yxdisk(3),yydisk(3),xxdisk(3),xydisknorm
   
   errStat = ErrID_None
   errMsg  = ''
   
   xydisk = (/0.0_ReKi, xhat_disk(1), 0.0_ReKi/)
   yxdisk = (/xhat_disk(2), 0.0_ReKi, 0.0_ReKi/)
   yydisk = (/0.0_ReKi, xhat_disk(2), 0.0_ReKi/)
   xxdisk = (/xhat_disk(1), 0.0_ReKi, 0.0_ReKi/)
   xydisknorm = TwoNorm(xxdisk + yydisk)
   
   if (EqualRealNos(xydisknorm,0.0_ReKi)) then
      ! TEST: E3
      call SetErrStat( ErrID_Fatal, 'Orientation of the rotor centerline at the rotor plane is directed vertically upward or downward, whereby the nacelle-yaw error and horizontal wake-deflection correction is undefined.', errStat, errMsg, 'GetYawCorrectionTermA' )
      return
   end if
 
   if (EqualRealNos(dx,0.0_ReKi)) then
      GetYawCorrection = ( p%C_HWkDfl_O + p%C_HWkDfl_OY*YawErr ) *      ( ( xydisk - yxdisk ) / (xydisknorm) )
   else
      GetYawCorrection = ( p%C_HWkDfl_x + p%C_HWkDfl_xY*yawErr ) * dx * ( ( xydisk - yxdisk ) / (xydisknorm) )
   end if
      
end function GetYawCorrection

!----------------------------------------------------------------------------------------------------------------------------------   
!> This subroutine calculates the eddy viscosity filter functions, prepresenting the delay in the turbulent stress generated by 
!! ambient turbulence or the development of turbulent stresses generated by the shear layer
real(ReKi) function EddyFilter(x_plane, D_rotor, C_Dmin, C_Dmax, C_Fmin, C_Exp)

   real(ReKi),          intent(in   ) :: x_plane         !< Downwind distance from rotor to each wake plane (m)
   real(ReKi),          intent(in   ) :: D_rotor         !< Rotor diameter (m)
   real(ReKi),          intent(in   ) :: C_Dmin          !< Calibrated parameter defining the transitional diameter fraction between the minimum and exponential regions
   real(ReKi),          intent(in   ) :: C_Dmax          !< Calibrated parameter defining the transitional diameter fraction between the exponential and maximum regions
   real(ReKi),          intent(in   ) :: C_Fmin          !< Calibrated parameter defining the functional value in the minimum region
   real(ReKi),          intent(in   ) :: C_Exp           !< Calibrated parameter defining the exponent in the exponential region


      ! Any errors due to invalid choices of the calibrated parameters have been raised when this module was initialized
   
   if ( x_plane <= C_Dmin*D_rotor ) then
      EddyFilter = C_Fmin
   else if (x_plane >= C_Dmax*D_rotor) then
      EddyFilter = 1_ReKi
   else
      EddyFilter = C_Fmin + (1_ReKi-C_Fmin)*( ( (x_plane/D_rotor) - C_DMin ) / (C_Dmax-C_Dmin) )**C_Exp
   end if


end function EddyFilter

!----------------------------------------------------------------------------------------------------------------------------------   
!> This subroutine calculates the wake diameter at a wake plane, based on one of four models
real(ReKi) function WakeDiam( Mod_WakeDiam, nr, dr, rArr, Vx_wake, Vx_wind_disk, D_rotor, C_WakeDiam)

   integer(intKi),      intent(in   ) :: Mod_WakeDiam       !< Wake diameter calculation model [ 1=Rotor diameter, 2=Velocity, 3=Mass flux, 4=Momentum flux]
   integer(intKi),      intent(in   ) :: nr                 !< Number of radii in the radial finite-difference grid
   real(ReKi),          intent(in   ) :: dr                 !< Radial increment of radial finite-difference grid (m)
   real(ReKi),          intent(in   ) :: rArr(0:)           !< Discretization of radial finite-difference grid (m)
   real(ReKi),          intent(in   ) :: Vx_wake(0:)        !< Axial wake velocity deficit at a wake plane, distributed radially (m/s)
   real(ReKi),          intent(in   ) :: Vx_wind_disk       !< Rotor-disk-averaged ambient wind speed, normal to planes (m/s)
   real(ReKi),          intent(in   ) :: D_rotor            !< Rotor diameter (m)
   real(ReKi),          intent(in   ) :: C_WakeDiam         !< Calibrated parameter for wake diameter calculation

   integer(IntKi) :: ILo
   real(ReKi) :: m(0:nr-1)
   integer(IntKi) :: i
   ILo = 0
    
   ! Any errors due to invalid values of dr and C_WakeDiam have been raised when this module was initialized
   
   select case ( Mod_WakeDiam )
      case (WakeDiamMod_RotDiam) 
      
         WakeDiam = D_rotor
         
      case (WakeDiamMod_Velocity)  
         
            ! Ensure the wake diameter is at least as large as the rotor diameter   
         
         WakeDiam = max(D_rotor, 2.0_ReKi*WD_Interp( (C_WakeDiam-1_ReKi)*Vx_wind_disk, rArr, Vx_wake ) )
         
      case (WakeDiamMod_MassFlux) 
         
         m(0) = 0.0
         do i = 1,nr-1
            m(i) = m(i-1) + pi*dr*(Vx_wake(i)*rArr(i) + Vx_wake(i-1)*rArr(i-1))
         end do
         
         WakeDiam = max(D_rotor, 2.0_ReKi*WD_Interp( C_WakeDiam*m(nr-1), rArr, m ) )
         
      case (WakeDiamMod_MtmFlux)
         
         m(0) = 0.0
         do i = 1,nr-1
            m(i) = m(i-1) + pi*dr*( (Vx_wake(i)**2)*rArr(i) + (Vx_wake(i-1)**2)*rArr(i-1))
         end do
         
         WakeDiam = max(D_rotor, 2.0_ReKi*WD_Interp( C_WakeDiam*m(nr-1), rArr, m ) )
   
   end select

      
end function WakeDiam


!----------------------------------------------------------------------------------------------------------------------------------   
!> This subroutine computes the near wake correction : Vx_wake  
subroutine NearWakeCorrection( Ct_azavg_filt, Vx_rel_disk_filt, p, m, Vx_wake, errStat, errMsg )
   real(ReKi),                   intent(in   ) :: Ct_azavg_filt(0:) !< Time-filtered azimuthally averaged thrust force coefficient (normal to disk), distributed radially
   real(ReKi),                   intent(in   ) :: Vx_rel_disk_filt  !< Time-filtered rotor-disk-averaged relative wind speed (ambient + deficits + motion), normal to disk
   type(WD_ParameterType),       intent(in   ) :: p                 !< Parameters
   type(WD_MiscVarType),         intent(inout) :: m                 !< Initial misc/optimization variables
   real(ReKi),                   intent(inout) :: Vx_wake(0:,0:)    !< Axial wake velocity deficit at wake planes, distributed radially
   integer(IntKi),               intent(  out) :: errStat           !< Error status of the operation
   character(*),                 intent(  out) :: errMsg            !< Error message if errStat /= ErrID_None
   real(ReKi)     :: a_interp
   integer(IntKi) :: j, ILo
   character(*), parameter            :: RoutineName = 'NearWakeCorrection'
   
   errStat = ErrID_None
   errMsg  = ''
   
   m%r_wake(0) = 0.0_ReKi
   
   do j=0,p%NumRadii-1
         
         ! compute m%a using the [n+1] values of Ct_azavg_filt
      if ( Ct_azavg_filt(j) > 2.0_ReKi ) then
         ! THROW ERROR because we are in the prop-brake region
         ! TEST: E5
         call SetErrStat(ErrID_FATAL, 'Wake model is not valid in the propeller-brake region, i.e., Ct_azavg_filt(j) > 2.0.', errStat, errMsg, RoutineName) 
         
         return
      else if ( Ct_azavg_filt(j) >= 24.0_ReKi/25.0_ReKi ) then
         m%a(j) = (2.0_ReKi + 3.0_ReKi*sqrt(14.0_ReKi*Ct_azavg_filt(j)-12.0_ReKi))/14.0_ReKi
      else
         m%a(j) =  0.5_ReKi - 0.5_ReKi*sqrt( 1.0_ReKi-Ct_azavg_filt(j))
      end if
      
      !if ( EqualRealNos(m%a(j),(1.0_ReKi / p%C_NearWake)) .or.  (m%a(j) > (1.0_ReKi / p%C_NearWake)) ) then
      !   ! TEST: E6
      !   call SetErrStat(ErrID_FATAL, 'Local induction is high enough to invalidate the near-wake correction, i.e., m%a(i) >= 1.0_ReKi / p%C_NearWake.', errStat, errMsg, RoutineName) 
      !   return
      !end if
      ! Bounding inductions that is too-high
      if ( m%a(j)>= 0.95*(1.0_ReKi / p%C_NearWake)) then
         write(*,'(A,F8.2,A,F6.3,A,F6.3)')'>>> a too high r=',p%r(j),' a=',m%a(j),' Ct=',Ct_azavg_filt(j)
         m%a(j) = 0.95*(1.0_ReKi / p%C_NearWake)
      endif
      if (j > 0) then
         m%r_wake(j) = sqrt(m%r_wake(j-1)**2 + p%dr*( ((1.0_ReKi - m%a(j))*p%r(j)) / (1.0_ReKi-p%C_NearWake*m%a(j)) + ((1.0_ReKi - m%a(j-1))*p%r(j-1)) / (1.0_ReKi-p%C_NearWake*m%a(j-1)) ) )
      end if
      
   end do
   
   ! NOTE: We need another loop over NumRadii because we need the complete m%a() vector so that we can interpolate into m%a() using the value of r_wake
   
      ! Use the [n+1] version of Vx_rel_disk_filt to determine the [n+1] version of Vx_wake(:,0)
   Vx_wake(0,0) = -Vx_rel_disk_filt*p%C_Nearwake*m%a(0)
   
   ILo = 0
   do j=1, p%NumRadii-1     
     
      ! given r_wake and m%a at p%dr increments, find value of m%a(r_wake) using interpolation 
      a_interp = InterpBin( p%r(j),m%r_wake, m%a, ILo, p%NumRadii ) !( XVal, XAry, YAry, ILo, AryLen )
      
         !                 [n+1] 
      Vx_wake(j,0) = -Vx_rel_disk_filt*p%C_NearWake*a_interp

   end do
   
end subroutine NearWakeCorrection



!----------------------------------------------------------------------------------------------------------------------------------   
!> This subroutine solves the tridiagonal linear system for x() using the Thomas algorithm   
subroutine ThomasAlgorithm(nr, a, b, c, d, x, errStat, errMsg)

   integer(IntKi),      intent(in   ) :: nr                 !< Number of radii in the radial finite-difference grid
   real(ReKi),          intent(inout) :: a(0:)              !< Sub diagonal
   real(ReKi),          intent(inout) :: b(0:)              !< Main diagonal
   real(ReKi),          intent(inout) :: c(0:)              !< Super diagonal
   real(ReKi),          intent(inout) :: d(0:)              !< Right-hand side
   real(ReKi),          intent(inout) :: x(0:)              !< Solution of the linear solve
   integer(IntKi),      intent(  out) :: errStat            !< Error status of the operation
   character(*),        intent(  out) :: errMsg             !< Error message if errStat /= ErrID_None
   real(ReKi)     :: m
   integer(IntKi) :: i
   character(*), parameter            :: RoutineName = 'ThomasAlgorithm'
   
   errStat = ErrID_None
   errMsg  = ''
   
   ! Assumes all arrays are the same length
   
      ! Check that tridiagonal matrix is not diagonally dominant
   if ( abs(b(0)) <= abs(c(0)) ) then
      ! TEST: E16
       call SetErrStat( ErrID_Fatal, 'Tridiagonal matrix is not diagonally dominant, i.e., abs(b(0)) <= abs(c(0)). Try reducing the FAST.Farm timestep.', errStat, errMsg, RoutineName )
       return
   end if
   do i = 1,nr-2
      if ( abs(b(i)) <= ( abs(a(i))+abs(c(i)) ) ) then
         ! TEST: E17
          call SetErrStat( ErrID_Fatal, 'Tridiagonal matrix is not diagonally dominant, i.e., abs(b(i)) <= ( abs(a(i))+abs(c(i)) ). Try reducing the FAST.Farm timestep.', errStat, errMsg, RoutineName )
          return
      end if
   end do
   if ( abs(b(nr-1)) <= abs(a(nr-1)) ) then
      ! TEST: E18
       call SetErrStat( ErrID_Fatal, 'Tridiagonal matrix is not diagonally dominant, i.e., abs(b(nr-1)) <= abs(a(nr-1)). Try reducing the FAST.Farm timestep.', errStat, errMsg, RoutineName )
       return
   end if
   
   do i = 1,nr-1 
      m = -a(i)/b(i-1)
      b(i) = b(i) +  m*c(i-1)
      d(i) = d(i) +  m*d(i-1)
   end do
   
   x(nr-1) = d(nr-1)/b(nr-1)
   do i = nr-2,0, -1
      x(i) = ( d(i) - c(i)*x(i+1) ) / b(i)
   end do

end subroutine ThomasAlgorithm

!----------------------------------------------------------------------------------------------------------------------------------   
!> This routine is called at the start of the simulation to perform initialization steps.
!! The parameters are set here and not changed during the simulation.
!! The initial states and initial guess for the input are defined.
subroutine WD_Init( InitInp, u, p, x, xd, z, OtherState, y, m, Interval, InitOut, errStat, errMsg )
!..................................................................................................................................

   type(WD_InitInputType),       intent(in   ) :: InitInp       !< Input data for initialization routine
   type(WD_InputType),           intent(  out) :: u             !< An initial guess for the input; input mesh must be defined
   type(WD_ParameterType),       intent(  out) :: p             !< Parameters
   type(WD_ContinuousStateType), intent(  out) :: x             !< Initial continuous states
   type(WD_DiscreteStateType),   intent(  out) :: xd            !< Initial discrete states
   type(WD_ConstraintStateType), intent(  out) :: z             !< Initial guess of the constraint states
   type(WD_OtherStateType),      intent(  out) :: OtherState    !< Initial other states
   type(WD_OutputType),          intent(  out) :: y             !< Initial system outputs (outputs are not calculated;
                                                                !!   only the output mesh is initialized)
   type(WD_MiscVarType),         intent(  out) :: m             !< Initial misc/optimization variables
   real(DbKi),                   intent(in   ) :: interval      !< Coupling interval in seconds: the rate that
                                                                !!   (1) WD_UpdateStates() is called in loose coupling &
                                                                !!   (2) WD_UpdateDiscState() is called in tight coupling.
                                                                !!   Input is the suggested time from the glue code;
                                                                !!   Output is the actual coupling interval that will be used
                                                                !!   by the glue code.
   type(WD_InitOutputType),      intent(  out) :: InitOut       !< Output for initialization routine
   integer(IntKi),               intent(  out) :: errStat       !< Error status of the operation
   character(*),                 intent(  out) :: errMsg        !< Error message if errStat /= ErrID_None
   

      ! Local variables
   integer(IntKi)                              :: i             ! loop counter
   
   integer(IntKi)                              :: errStat2      ! temporary error status of the operation
   character(ErrMsgLen)                        :: errMsg2       ! temporary error message 
   character(*), parameter                     :: RoutineName = 'WD_Init'
   
   
      ! Initialize variables for this routine

   errStat = ErrID_None
   errMsg  = ""
  
      ! Initialize the NWTC Subroutine Library

   call NWTC_Init( EchoLibVer=.FALSE. )

   
      ! Display the module information

   if (InitInp%TurbNum <= 1) call DispNVD( WD_Ver )       
      
      ! Validate the initialization inputs
   call ValidateInitInputData( interval, InitInp, InitInp%InputFileData, ErrStat2, ErrMsg2 )
      call SetErrStat( ErrStat2, ErrMsg2, errStat, errMsg, RoutineName ) 
      if (errStat >= AbortErrLev) return
      
      !............................................................................................
      ! Define parameters
      !............................................................................................
      
   
      
      ! set the rest of the parameters
   p%DT            = interval         
   p%NumPlanes     = InitInp%InputFileData%NumPlanes   
   p%NumRadii      = InitInp%InputFileData%NumRadii    
   p%dr            = InitInp%InputFileData%dr  
   p%C_HWkDfl_O    = InitInp%InputFileData%C_HWkDfl_O 
   p%C_HWkDfl_OY   = InitInp%InputFileData%C_HWkDfl_OY
   p%C_HWkDfl_x    = InitInp%InputFileData%C_HWkDfl_x 
   p%C_HWkDfl_xY   = InitInp%InputFileData%C_HWkDfl_xY
   p%C_NearWake    = InitInp%InputFileData%C_NearWake  
   p%C_vAmb_DMin   = InitInp%InputFileData%C_vAmb_DMin 
   p%C_vAmb_DMax   = InitInp%InputFileData%C_vAmb_DMax 
   p%C_vAmb_FMin   = InitInp%InputFileData%C_vAmb_FMin 
   p%C_vAmb_Exp    = InitInp%InputFileData%C_vAmb_Exp  
   p%C_vShr_DMin   = InitInp%InputFileData%C_vShr_DMin 
   p%C_vShr_DMax   = InitInp%InputFileData%C_vShr_DMax 
   p%C_vShr_FMin   = InitInp%InputFileData%C_vShr_FMin 
   p%C_vShr_Exp    = InitInp%InputFileData%C_vShr_Exp  
   p%k_vAmb        = InitInp%InputFileData%k_vAmb      
   p%k_vShr        = InitInp%InputFileData%k_vShr      
   p%Mod_WakeDiam  = InitInp%InputFileData%Mod_WakeDiam
   p%C_WakeDiam    = InitInp%InputFileData%C_WakeDiam  
   
   allocate( p%r(0:p%NumRadii-1),stat=errStat2)
      if (errStat2 /= 0) then
         call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for p%r.', errStat, errMsg, RoutineName )
         return
      end if
      
   do i = 0,p%NumRadii-1
      p%r(i)       = p%dr*i     
   end do
   
   p%filtParam         = exp(-2.0_ReKi*pi*p%dt*InitInp%InputFileData%f_c)
   p%oneMinusFiltParam = 1.0_ReKi - p%filtParam
      !............................................................................................
      ! Define and initialize inputs here 
      !............................................................................................
   
   allocate( u%V_plane       (3,0:p%NumPlanes-1),stat=errStat2)
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for u%V_plane.', errStat, errMsg, RoutineName )
   allocate( u%Ct_azavg      (  0:p%NumRadii-1 ),stat=errStat2)
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for u%Ct_azavg.', errStat, errMsg, RoutineName )   
   if (errStat /= ErrID_None) return
   

         
      
      !............................................................................................
      ! Define outputs here
      !............................................................................................

   
   
      !............................................................................................
      ! Initialize states and misc vars : Note these are not the correct initializations because
      ! that would require valid input data, which we do not have here.  Instead we will check for
      ! an firstPass flag on the miscVars and if it is false we will properly initialize these state
      ! in CalcOutput or UpdateStates, as necessary.
      !............................................................................................
      
   allocate ( xd%xhat_plane       (3, 0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%xhat_plane.', errStat, errMsg, RoutineName )   
   allocate ( xd%p_plane          (3, 0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%p_plane.', errStat, errMsg, RoutineName )   
   allocate ( xd%V_plane_filt     (3, 0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%V_plane_filt.', errStat, errMsg, RoutineName )
   allocate ( xd%Vx_wind_disk_filt(0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%Vx_wind_disk_filt.', errStat, errMsg, RoutineName )   
   allocate ( xd%x_plane          (0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%x_plane.', errStat, errMsg, RoutineName )   
   allocate ( xd%YawErr_filt      (0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%YawErr_filt.', errStat, errMsg, RoutineName )   
   allocate ( xd%TI_amb_filt      (0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%TI_amb_filt.', errStat, errMsg, RoutineName )   
   allocate ( xd%D_rotor_filt     (0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%D_rotor_filt.', errStat, errMsg, RoutineName )   
   allocate ( xd%Ct_azavg_filt    (0:p%NumRadii-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%Ct_azavg_filt.', errStat, errMsg, RoutineName )   
   allocate ( xd%Vx_wake     (0:p%NumRadii-1,0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%Vx_wake.', errStat, errMsg, RoutineName )   
   allocate ( xd%Vr_wake     (0:p%NumRadii-1,0:p%NumPlanes-1) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for xd%Vr_wake.', errStat, errMsg, RoutineName )   
   if (errStat /= ErrID_None) return

   xd%xhat_plane          = 0.0_ReKi
   xd%p_plane             = 0.0_ReKi
   xd%x_plane             = 0.0_ReKi
   xd%Vx_wake             = 0.0_ReKi
   xd%Vr_wake             = 0.0_ReKi
   xd%V_plane_filt        = 0.0_ReKi
   xd%Vx_wind_disk_filt   = 0.0_ReKi
   xd%TI_amb_filt         = 0.0_ReKi
   xd%D_rotor_filt        = 0.0_ReKi
   xd%Vx_rel_disk_filt    = 0.0_ReKi
   xd%Ct_azavg_filt       = 0.0_ReKi
   OtherState%firstPass            = .true.     
   
      ! miscvars to avoid the allocation per timestep
   allocate ( m%dvdr(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%dvdr.', errStat, errMsg, RoutineName )   
   allocate ( m%dvtdr(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%dvtdr.', errStat, errMsg, RoutineName )  
   allocate (   m%vt_tot(0:p%NumRadii-1,0:p%NumPlanes-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%vt_tot.', errStat, errMsg, RoutineName )  
   allocate (   m%vt_amb(0:p%NumRadii-1,0:p%NumPlanes-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%vt_amb.', errStat, errMsg, RoutineName )  
   allocate (   m%vt_shr(0:p%NumRadii-1,0:p%NumPlanes-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%vt_shr.', errStat, errMsg, RoutineName )  

   allocate (    m%a(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%a.', errStat, errMsg, RoutineName )  
   allocate (    m%b(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%b.', errStat, errMsg, RoutineName )  
   allocate (    m%c(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%c.', errStat, errMsg, RoutineName )  
   allocate (    m%d(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%d.', errStat, errMsg, RoutineName )  
   allocate (    m%r_wake(0:p%NumRadii-1 ) , STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for m%r_wake.', errStat, errMsg, RoutineName )  
   if (errStat /= ErrID_None) return
   
      !............................................................................................
      ! Define initialization output here
      !............................................................................................
   
   InitOut%Ver = WD_Ver
   
   allocate ( y%xhat_plane(3,0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%xhat_plane.', errStat, errMsg, RoutineName )     
   allocate ( y%p_plane   (3,0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%p_plane.', errStat, errMsg, RoutineName )  
   allocate ( y%Vx_wake   (0:p%NumRadii-1,0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%Vx_wake.', errStat, errMsg, RoutineName )  
   allocate ( y%Vr_wake   (0:p%NumRadii-1,0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%Vr_wake.', errStat, errMsg, RoutineName )  
   allocate ( y%D_wake    (0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%D_wake.', errStat, errMsg, RoutineName )  
   allocate ( y%x_plane   (0:p%NumPlanes-1), STAT=ErrStat2 )
      if (errStat2 /= 0) call SetErrStat ( ErrID_Fatal, 'Could not allocate memory for y%x_plane.', errStat, errMsg, RoutineName )  
   if (errStat /= ErrID_None) return
   
   y%xhat_plane = 0.0_Reki
   y%p_plane    = 0.0_Reki
   y%Vx_wake    = 0.0_Reki
   y%Vr_wake    = 0.0_Reki
   y%D_wake     = 0.0_Reki
   y%x_plane    = 0.0_Reki

      
end subroutine WD_Init

!----------------------------------------------------------------------------------------------------------------------------------
!> This routine is called at the end of the simulation.
subroutine WD_End( u, p, x, xd, z, OtherState, y, m, errStat, errMsg )
!..................................................................................................................................

      type(WD_InputType),           intent(inout)  :: u           !< System inputs
      type(WD_ParameterType),       intent(inout)  :: p           !< Parameters
      type(WD_ContinuousStateType), intent(inout)  :: x           !< Continuous states
      type(WD_DiscreteStateType),   intent(inout)  :: xd          !< Discrete states
      type(WD_ConstraintStateType), intent(inout)  :: z           !< Constraint states
      type(WD_OtherStateType),      intent(inout)  :: OtherState  !< Other states
      type(WD_OutputType),          intent(inout)  :: y           !< System outputs
      type(WD_MiscVarType),         intent(inout)  :: m           !< Misc/optimization variables
      integer(IntKi),               intent(  out)  :: errStat     !< Error status of the operation
      character(*),                 intent(  out)  :: errMsg      !< Error message if errStat /= ErrID_None



         ! Initialize errStat

      errStat = ErrID_None
      errMsg  = ""


         ! Place any last minute operations or calculations here:


         ! Close files here:



         ! Destroy the input data:

      call WD_DestroyInput( u, errStat, errMsg )


         ! Destroy the parameter data:

      call WD_DestroyParam( p, errStat, errMsg )


         ! Destroy the state data:

      call WD_DestroyContState(   x,           errStat, errMsg )
      call WD_DestroyDiscState(   xd,          errStat, errMsg )
      call WD_DestroyConstrState( z,           errStat, errMsg )
      call WD_DestroyOtherState(  OtherState,  errStat, errMsg )
      call WD_DestroyMisc(        m,           errStat, errMsg ) 

         ! Destroy the output data:

      call WD_DestroyOutput( y, errStat, errMsg )




end subroutine WD_End
!----------------------------------------------------------------------------------------------------------------------------------
!> Loose coupling routine for solving for constraint states, integrating continuous states, and updating discrete and other states.
!! Continuous, constraint, discrete, and other states are updated for t + Interval
subroutine WD_UpdateStates( t, n, u, p, x, xd, z, OtherState, m, errStat, errMsg )
!..................................................................................................................................

   real(DbKi),                     intent(in   ) :: t          !< Current simulation time in seconds
   integer(IntKi),                 intent(in   ) :: n          !< Current simulation time step n = 0,1,...
   type(WD_InputType),             intent(in   ) :: u          !< Inputs at utimes (out only for mesh record-keeping in ExtrapInterp routine)
  ! real(DbKi),                     intent(in   ) :: utimes   !< Times associated with u(:), in seconds
   type(WD_ParameterType),         intent(in   ) :: p          !< Parameters
   type(WD_ContinuousStateType),   intent(inout) :: x          !< Input: Continuous states at t;
                                                               !!   Output: Continuous states at t + Interval
   type(WD_DiscreteStateType),     intent(inout) :: xd         !< Input: Discrete states at t;
                                                               !!   Output: Discrete states at t  + Interval
   type(WD_ConstraintStateType),   intent(inout) :: z          !< Input: Constraint states at t;
                                                               !!   Output: Constraint states at t+dt
   type(WD_OtherStateType),        intent(inout) :: OtherState !< Input: Other states at t;
                                                               !!   Output: Other states at t+dt
   type(WD_MiscVarType),           intent(inout) :: m          !< Misc/optimization variables
   integer(IntKi),                 intent(  out) :: errStat    !< Error status of the operation
   character(*),                   intent(  out) :: errMsg     !< Error message if errStat /= ErrID_None

   ! local variables
   type(WD_InputType)                           :: uInterp           ! Interpolated/Extrapolated input
   integer(intKi)                               :: errStat2          ! temporary Error status
   character(ErrMsgLen)                         :: errMsg2           ! temporary Error message
   character(*), parameter                      :: RoutineName = 'WD_UpdateStates'
   real(ReKi)                                   :: dx, norm2_xhat_plane  
   real(ReKi)                                   :: dy_HWkDfl(3), EddyTermA, EddyTermB, lstar, Vx_wake_min
   integer(intKi)                               :: i,j, maxPln
   
   errStat = ErrID_None
   errMsg  = ""
   
   
   if ( EqualRealNos(u%D_Rotor,0.0_ReKi) .or. u%D_Rotor < 0.0_ReKi ) then
      ! TEST: E7
      call SetErrStat(ErrID_Fatal, 'Rotor diameter must be greater than zero.', errStat, errMsg, RoutineName)
      return
   end if
   
      ! Check if we are fully initialized
   if ( OtherState%firstPass ) then
      call InitStatesWithInputs(p%NumPlanes, p%NumRadii, u, p, xd, m, errStat2, errMsg2)
         call SetErrStat(errStat2, errMsg2, errStat, errMsg, RoutineName)
      OtherState%firstPass = .false.        
      if (errStat >= AbortErrLev) then
         ! TEST: E3 
         return
      end if
      
   end if         
   

   ! Update V_plane_filt to [n+1]:
   
   maxPln = min(n,p%NumPlanes-2)
   do i = 0,maxPln 
      xd%V_plane_filt(:,i       ) = xd%V_plane_filt(:,i)*p%filtParam + u%V_plane(:,i       )*p%oneMinusFiltParam
   end do
   xd%V_plane_filt   (:,maxPln+1) =                                    u%V_plane(:,maxPln+1)

   
   maxPln = min(n+2,p%NumPlanes-1)

      ! create eddy viscosity info for most downstream plane
   i = maxPln+1
   lstar = WakeDiam( p%Mod_WakeDiam, p%numRadii, p%dr, p%r, xd%Vx_wake(:,i-1), xd%Vx_wind_disk_filt(i-1), xd%D_rotor_filt(i-1), p%C_WakeDiam) / 2.0_ReKi     
   
   Vx_wake_min = huge(ReKi)
   do j = 0,p%NumRadii-1
      Vx_wake_min = min(Vx_wake_min, xd%Vx_wake(j,i-1))
   end do
        
   EddyTermA = EddyFilter(xd%x_plane(i-1),xd%D_rotor_filt(i-1), p%C_vAmb_DMin, p%C_vAmb_DMax, p%C_vAmb_FMin, p%C_vAmb_Exp) * p%k_vAmb * xd%TI_amb_filt(i-1) * xd%Vx_wind_disk_filt(i-1) * xd%D_rotor_filt(i-1)/2.0_ReKi
   EddyTermB = EddyFilter(xd%x_plane(i-1),xd%D_rotor_filt(i-1), p%C_vShr_DMin, p%C_vShr_DMax, p%C_vShr_FMin, p%C_vShr_Exp) * p%k_vShr
   do j = 0,p%NumRadii-1      
      if ( j == 0 ) then
         m%dvdr(j) =   0.0_ReKi
      elseif (j <= p%NumRadii-2) then
         m%dvdr(j) = ( xd%Vx_wake(j+1,i-1) - xd%Vx_wake(j-1,i-1) ) / (2_ReKi*p%dr)
      else
         m%dvdr(j) = - xd%Vx_wake(j-1,i-1)  / (2_ReKi*p%dr)
      end if
       !     All of the following states are at [n] 
      m%vt_amb(j,i-1) = EddyTermA
      m%vt_shr(j,i-1) = EddyTermB * max( (lstar**2)*abs(m%dvdr(j)) , lstar*(xd%Vx_wind_disk_filt(i-1) + Vx_wake_min ) )
      m%vt_tot(j,i-1) = m%vt_amb(j,i-1) + m%vt_shr(j,i-1)                                                   
   end do   
  
      ! We are going to update Vx_Wake
      ! The quantities in these loops are all at time [n], so we need to compute prior to updating the states to [n+1]
   do i = maxPln, 1, -1  
    
      lstar = WakeDiam( p%Mod_WakeDiam, p%numRadii, p%dr, p%r, xd%Vx_wake(:,i-1), xd%Vx_wind_disk_filt(i-1), xd%D_rotor_filt(i-1), p%C_WakeDiam) / 2.0_ReKi     

         ! The following two quantities need to be for the time increments:
         !           [n+1]             [n]
         ! dx      = xd%x_plane(i) - xd%x_plane(i-1)
         ! This is equivalent to
      
      dx = dot_product(xd%xhat_plane(:,i-1),xd%V_plane_filt(:,i-1))*p%DT
      
      if ( EqualRealNos(dx, 0.0_ReKi) .or. dx < 0.0_ReKi) then
         ! TEST: E2
         call SetErrStat(ErrID_FATAL, 'Downwind advection speed of a wake plane is not positive, i.e., dot_product(xd%xhat_plane(:,i-1),xd%V_plane_filt(:,i-1))*DT<= 0', errStat, errMsg, RoutineName)   
         return
      end if
      
      Vx_wake_min = huge(ReKi)
      do j = 0,p%NumRadii-1
         Vx_wake_min = min(Vx_wake_min, xd%Vx_wake(j,i-1))
      end do
        
      EddyTermA = EddyFilter(xd%x_plane(i-1),xd%D_rotor_filt(i-1), p%C_vAmb_DMin, p%C_vAmb_DMax, p%C_vAmb_FMin, p%C_vAmb_Exp) * p%k_vAmb * xd%TI_amb_filt(i-1) * xd%Vx_wind_disk_filt(i-1) * xd%D_rotor_filt(i-1)/2.0_ReKi
      EddyTermB = EddyFilter(xd%x_plane(i-1),xd%D_rotor_filt(i-1), p%C_vShr_DMin, p%C_vShr_DMax, p%C_vShr_FMin, p%C_vShr_Exp) * p%k_vShr
      do j = 0,p%NumRadii-1      
         if ( j == 0 ) then
          m%dvdr(j) =   0.0_ReKi
         elseif (j <= p%NumRadii-2) then
            m%dvdr(j) = ( xd%Vx_wake(j+1,i-1) - xd%Vx_wake(j-1,i-1) ) / (2_ReKi*p%dr)
         else
            m%dvdr(j) = - xd%Vx_wake(j-1,i-1)  / (2_ReKi*p%dr)
         end if
            ! All of the following states are at [n] 
         m%vt_amb(j,i-1) = EddyTermA
         m%vt_shr(j,i-1) = EddyTermB * max( (lstar**2)*abs(m%dvdr(j)) , lstar*(xd%Vx_wind_disk_filt(i-1) + Vx_wake_min ) )
         m%vt_tot(j,i-1) = m%vt_amb(j,i-1) + m%vt_shr(j,i-1)                                                   
      end do
      
         ! All of the m%a,m%b,m%c,m%d vectors use states at time increment [n]
         ! These need to be inside another radial loop because m%dvtdr depends on the j+1 and j-1 indices of m%vt()
      
      m%dvtdr(0) = 0.0_ReKi
      m%a(0)     = 0.0_ReKi
      m%b(0)     = p%dr * ( xd%Vx_wind_disk_filt(i-1) + xd%Vx_wake(0,i-1)  ) / dx + m%vt_tot(0,i-1)/p%dr
      m%c(0)     = -m%vt_tot(0,i-1)/p%dr
      m%c(p%NumRadii-1) = 0.0_ReKi
      m%d(0)     = (p%dr * (xd%Vx_wind_disk_filt(i-1) + xd%Vx_wake(0,i-1)) / dx - m%vt_tot(0,i-1)/p%dr  ) * xd%Vx_wake(0,i-1) + ( m%vt_tot(0,i-1)/p%dr ) * xd%Vx_wake(1,i-1) 
      
      do j = p%NumRadii-1, 1, -1 
         
         if (j <= p%NumRadii-2) then
            m%dvtdr(j) = ( m%vt_tot(j+1,i-1) - m%vt_tot(j-1,i-1) ) / (2_ReKi*p%dr)
            m%c(j) = real(j,ReKi)*xd%Vr_wake(j,i-1)/4.0_ReKi - (1_ReKi+2_ReKi*real(j,ReKi))*m%vt_tot(j,i-1)/(4.0_ReKi*p%dr) - real(j,ReKi)*m%dvtdr(j)/4.0_ReKi
            m%d(j) =    ( real(j,ReKi)*xd%Vr_wake(j,i-1)/4.0_ReKi - (1_ReKi-2_ReKi*real(j,ReKi))*m%vt_tot(j,i-1)/(4.0_ReKi*p%dr) - real(j,ReKi)*m%dvtdr(j)/4.0_ReKi) * xd%Vx_wake(j-1,i-1) &
                    + ( p%r(j)*( xd%Vx_wind_disk_filt(i-1) + xd%Vx_wake(j,i-1)  )/dx -  real(j,ReKi)*m%vt_tot(j,i-1)/p%dr  ) * xd%Vx_wake(j,i-1) &
                    + (-real(j,ReKi)*xd%Vr_wake(j,i-1)/4.0_ReKi + (1_ReKi+2_ReKi*real(j,ReKi))*m%vt_tot(j,i-1)/(4.0_ReKi*p%dr) + real(j,ReKi)*m%dvtdr(j)/4.0_ReKi ) * xd%Vx_wake(j+1,i-1)
             
         else
            m%dvtdr(j) = 0.0_ReKi
            m%d(j) = ( real(j,ReKi)*xd%Vr_wake(j,i-1)/4.0_ReKi - (1_ReKi-2_ReKi*real(j,ReKi))*m%vt_tot(j,i-1)/(4.0_ReKi*p%dr) - real(j,ReKi)*m%dvtdr(j)/4.0_ReKi) * xd%Vx_wake(j-1,i-1) &
                    + ( p%r(j)*( xd%Vx_wind_disk_filt(i-1) + xd%Vx_wake(j,i-1)  )/dx -  real(j,ReKi)*m%vt_tot(j,i-1)/p%dr  ) * xd%Vx_wake(j,i-1) 
                    
         end if  
         
         m%a(j) = -real(j,ReKi)*xd%Vr_wake(j,i-1)/4.0_ReKi + (1.0_ReKi-2.0_ReKi*real(j,ReKi))*m%vt_tot(j,i-1)/(4.0_ReKi*p%dr) + real(j,ReKi)*m%dvtdr(j)/4.0_ReKi 
         m%b(j) = p%r(j) * ( xd%Vx_wind_disk_filt(i-1) + xd%Vx_wake(j,i-1)  ) / dx + real(j,ReKi)*m%vt_tot(j,i-1)/p%dr
         
        
      end do ! j = 1,p%NumRadii-1
   
         ! Update these states to [n+1]

      xd%x_plane     (i) = xd%x_plane    (i-1) + dx   ! dx = dot_product(xd%xhat_plane(:,i-1),xd%V_plane_filt(:,i-1))*p%DT   
      xd%YawErr_filt (i) = xd%YawErr_filt(i-1)
      xd%xhat_plane(:,i) = xd%xhat_plane(:,i-1)
      
         ! The function state-related arguments must be at time [n+1], so we must update YawErr_filt and xhat_plane before computing the deflection
      
      dy_HWkDfl = GetYawCorrection(xd%YawErr_filt(i), xd%xhat_plane(:,i), dx, p, errStat2, errMsg2)
         call SetErrStat(errStat2, errMsg2, errStat, errMsg, RoutineName)   
         if (errStat >= AbortErrLev) then
            ! TEST: E3          
            call Cleanup()
            return
         end if
      xd%p_plane        (:,i) =  xd%p_plane(:,i-1) + xd%xhat_plane(:,i-1)*dx + dy_HWkDfl &
                              + ( u%V_plane(:,i-1) - xd%xhat_plane(:,i-1)*dot_product(xd%xhat_plane(:,i-1),u%V_plane(:,i-1)) )*p%DT
         
      xd%Vx_wind_disk_filt(i) = xd%Vx_wind_disk_filt(i-1)
      xd%TI_amb_filt      (i) = xd%TI_amb_filt(i-1)
      xd%D_rotor_filt     (i) = xd%D_rotor_filt(i-1)
      
         ! Update Vx_wake to [n+1]
      call ThomasAlgorithm(p%NumRadii, m%a, m%b, m%c, m%d, xd%Vx_wake(:,i), errStat2, errMsg2)
         call SetErrStat(errStat2, errMsg2, errStat, errMsg, RoutineName) 
         if (errStat >= AbortErrLev) then
            ! TEST: E16, E17, or E18
            call Cleanup()
            return
         end if  
      do j = 1,p%NumRadii-1
            ! NOTE: xd%Vr_wake(0,:) was initialized to 0 and remains 0.
         xd%Vr_wake(j,i) = real(  j-1,ReKi)*(  xd%Vr_wake(j-1,i)  )/real(j,ReKi) &
            !  Vx_wake is for the                         [n+1]       ,      [n+1]        ,      [n]          , and    [n]        increments             
                         - real(2*j-1,ReKi)*p%dr * (  xd%Vx_wake(j,i) + xd%Vx_wake(j-1,i) - xd%Vx_wake(j,i-1) - xd%Vx_wake(j-1,i-1)  ) / ( real(4*j,ReKi) * dx )
      end do  
   end do ! i = 1,min(n+2,p%NumPlanes-1) 
 

      
      ! Update states at disk-plane to [n+1] 
      
   xd%xhat_plane     (:,0) =  xd%xhat_plane(:,0)*p%filtParam + u%xhat_disk(:)*p%oneMinusFiltParam  ! 2-step calculation for xhat_plane at disk
   norm2_xhat_plane        =  TwoNorm( xd%xhat_plane(:,0) ) 
   if ( EqualRealNos(norm2_xhat_plane, 0.0_ReKi) ) then
      ! TEST: E1
      call SetErrStat(ErrID_FATAL, 'The nacelle-yaw has rotated 180 degrees between time steps, i.e., the L2 norm of xd%xhat_plane(:,0)*p%filtParam + u%xhat_disk(:)*(1-p%filtParam) is zero.', errStat, errMsg, RoutineName) 
      call Cleanup()
      return
   end if
   
   xd%xhat_plane     (:,0) =  xd%xhat_plane(:,0) / norm2_xhat_plane
   
   xd%YawErr_filt      (0) =  xd%YawErr_filt(0)*p%filtParam + u%YawErr*p%oneMinusFiltParam
   
   if ( EqualRealNos(abs(xd%YawErr_filt(0)), pi/2) .or. abs(xd%YawErr_filt(0)) > pi/2 ) then
      ! TEST: E4
      call SetErrStat(ErrID_FATAL, 'The time-filtered nacelle-yaw error has reached +/- pi/2.', errStat, errMsg, RoutineName) 
      call Cleanup()
      return
   end if
   
      ! The function state-related arguments must be at time [n+1], so we must update YawErr_filt and xhat_plane before computing the deflection
   dx = 0.0_ReKi
   dy_HWkDfl = GetYawCorrection(xd%YawErr_filt(0), xd%xhat_plane(:,0), dx, p, errStat2, errMsg2)
      call SetErrStat(ErrStat2, ErrMsg2, errStat, errMsg, RoutineName)   
      if (errStat /= ErrID_None) then
         ! TEST: E3
         call Cleanup()
         return
      end if
      
   ! NOTE: xd%x_plane(0) was already initialized to zero
      
   xd%p_plane        (:,0) =  xd%p_plane(:,0)*p%filtParam + ( u%p_hub(:) + dy_HWkDfl(:) )*p%oneMinusFiltParam
   xd%Vx_wind_disk_filt(0) =  xd%Vx_wind_disk_filt(0)*p%filtParam + u%Vx_wind_disk*p%oneMinusFiltParam
   xd%TI_amb_filt      (0) =  xd%TI_amb_filt(0)*p%filtParam + u%TI_amb*p%oneMinusFiltParam
   xd%D_rotor_filt     (0) =  xd%D_rotor_filt(0)*p%filtParam + u%D_rotor*p%oneMinusFiltParam  
   xd%Vx_rel_disk_filt     =  xd%Vx_rel_disk_filt*p%filtParam + u%Vx_rel_disk*p%oneMinusFiltParam 
   
   
   do i = 1,maxPln
      if ( xd%x_plane(i) - xd%x_plane(i-1) <= 0.0_ReKi ) then
         call SetErrStat(ErrID_FATAL, 'In a 1D sense, wake plane '//trim(num2lstr(i-1))//' is further downstream than wake plane '//trim(num2lstr(i)), errStat, errMsg, RoutineName)   
         call Cleanup()
         return
      end if
      
      if ( ( dot_product( xd%xhat_plane(:,i-1), ( xd%p_plane(:,i) - xd%p_plane(:,i-1) ) ) <= 0.0_ReKi ) .or. &
           ( dot_product( xd%xhat_plane(:,i  ), ( xd%p_plane(:,i) - xd%p_plane(:,i-1) ) ) <= 0.0_ReKi ) )then
         call SetErrStat(ErrID_FATAL, 'In a 3D sense, wake plane '//trim(num2lstr(i-1))//' is further downstream than wake plane '//trim(num2lstr(i)), errStat, errMsg, RoutineName)   
         call Cleanup()
         return 
      end if
   end do
   
   
      !  filtered, azimuthally-averaged Ct values at each radial station
   xd%Ct_azavg_filt (:) = xd%Ct_azavg_filt(:)*p%filtParam + u%Ct_azavg(:)*p%oneMinusFiltParam
   
   call NearWakeCorrection( xd%Ct_azavg_filt, xd%Vx_rel_disk_filt, p, m, xd%Vx_wake, errStat, errMsg )
   
   !Used for debugging: write(51,'(I5,100(1x,ES10.2E2))') n, xd%x_plane(n), xd%x_plane(n)/xd%D_rotor_filt(n), xd%Vx_wind_disk_filt(n) + xd%Vx_wake(:,n), xd%Vr_wake(:,n)    
   
   call Cleanup()
   
contains
   subroutine Cleanup()
      
      
   
   end subroutine Cleanup
   
end subroutine WD_UpdateStates
!----------------------------------------------------------------------------------------------------------------------------------
!> Routine for computing outputs, used in both loose and tight coupling.
!! This subroutine is used to compute the output channels (motions and loads) and place them in the WriteOutput() array.
!! The descriptions of the output channels are not given here. Please see the included OutListParameters.xlsx sheet for
!! for a complete description of each output parameter.
subroutine WD_CalcOutput( t, u, p, x, xd, z, OtherState, y, m, errStat, errMsg )
! NOTE: no matter how many channels are selected for output, all of the outputs are calcalated
! All of the calculated output channels are placed into the m%AllOuts(:), while the channels selected for outputs are
! placed in the y%WriteOutput(:) array.
!..................................................................................................................................

   REAL(DbKi),                   INTENT(IN   )  :: t           !< Current simulation time in seconds
   TYPE(WD_InputType),           INTENT(IN   )  :: u           !< Inputs at Time t
   TYPE(WD_ParameterType),       INTENT(IN   )  :: p           !< Parameters
   TYPE(WD_ContinuousStateType), INTENT(IN   )  :: x           !< Continuous states at t
   TYPE(WD_DiscreteStateType),   INTENT(IN   )  :: xd          !< Discrete states at t
   TYPE(WD_ConstraintStateType), INTENT(IN   )  :: z           !< Constraint states at t
   TYPE(WD_OtherStateType),      INTENT(IN   )  :: OtherState  !< Other states at t
   TYPE(WD_OutputType),          INTENT(INOUT)  :: y           !< Outputs computed at t (Input only so that mesh con-
                                                               !!   nectivity information does not have to be recalculated)
   type(WD_MiscVarType),         intent(inout)  :: m           !< Misc/optimization variables
   INTEGER(IntKi),               INTENT(  OUT)  :: errStat     !< Error status of the operation
   CHARACTER(*),                 INTENT(  OUT)  :: errMsg      !< Error message if errStat /= ErrID_None


   integer, parameter                           :: indx = 1  
   integer(intKi)                               :: n, i
   integer(intKi)                               :: ErrStat2
   character(ErrMsgLen)                         :: ErrMsg2
   character(*), parameter                      :: RoutineName = 'WD_CalcOutput'
   real(ReKi)                                   :: correction(3)
   errStat = ErrID_None
   errMsg  = ""

   n = nint(t/p%DT)
   
      ! Check if we are fully initialized
   if ( OtherState%firstPass ) then
                        
      correction = 0.0_ReKi
      do i = 0, 1
         y%x_plane(i) = u%Vx_rel_disk*real(i,ReKi)*real(p%DT,ReKi)
       
         correction = correction + GetYawCorrection(u%YawErr, u%xhat_disk, y%x_plane(i), p,  errStat2, errMsg2)
            call SetErrStat(errStat2, errMsg2, errStat, errMsg, RoutineName)
            if (errStat >= AbortErrLev) then
               ! TEST: E3
               return
            end if
      
         y%p_plane   (:,i) = u%p_hub(:) + y%x_plane(i)*u%xhat_disk(:) + correction
         y%xhat_plane(:,i) = u%xhat_disk(:)
                 
         
            ! NOTE: Since we are in firstPass=T, then xd%Vx_wake is already set to zero, so just pass that into WakeDiam
         y%D_wake(i)  =  WakeDiam( p%Mod_WakeDiam, p%NumRadii, p%dr, p%r, xd%Vx_wake(:,i), u%Vx_wind_disk, u%D_rotor, p%C_WakeDiam)
            
         if ( (y%p_plane     (3,i) - y%D_wake(i)/2.0_ReKi) < 0 ) then
            call SetErrStat(ErrID_Warn, 'Wake boundary for wake plane '//trim(num2lstr(i))//' is below the ground.', errStat, errMsg, RoutineName)
         end if
         if ( y%p_plane     (3,i) < 0 ) then
            call SetErrStat(ErrID_FATAL, 'Wake center for wake plane '//trim(num2lstr(i))//' is below the ground.' , errStat, errMsg, RoutineName)
            return
         end if
      
      end do
     
         ! Initialze Vx_wake; Vr_wake is already initialized to zero, so, we don't need to do that here.
      call NearWakeCorrection( u%Ct_azavg, u%Vx_rel_disk, p, m, y%Vx_wake, errStat, errMsg )
         if (errStat > AbortErrLev)  return
      y%Vx_wake(:,1) = y%Vx_wake(:,0) 
 
      return
      
   else
      y%x_plane    = xd%x_plane
      y%p_plane    = xd%p_plane
      y%xhat_plane = xd%xhat_plane
      y%Vx_wake    = xd%Vx_wake
      y%Vr_wake    = xd%Vr_wake
      do i = 0, min(n+1,p%NumPlanes-1)
         
         y%D_wake(i)  =  WakeDiam( p%Mod_WakeDiam, p%NumRadii, p%dr, p%r, xd%Vx_wake(:,i), xd%Vx_wind_disk_filt(i), xd%D_rotor_filt(i), p%C_WakeDiam)
         if ( y%p_plane     (3,i) < 0.0_ReKi ) then
            call SetErrStat(ErrID_FATAL, 'Wake center for wake plane '//trim(num2lstr(i))//' is below the ground.' , errStat, errMsg, RoutineName)
            return
         else if ( (y%p_plane     (3,i) - y%D_wake(i)/2.0_ReKi) < 0.0_ReKi ) then
            call SetErrStat(ErrID_Warn, 'Wake boundary for wake plane '//trim(num2lstr(i))//' is below the ground.', errStat, errMsg, RoutineName)
         end if
         
         
      end do
   end if
   
end subroutine WD_CalcOutput

!----------------------------------------------------------------------------------------------------------------------------------
!> Tight coupling routine for solving for the residual of the constraint state equations
subroutine WD_CalcConstrStateResidual( Time, u, p, x, xd, z, OtherState, m, z_residual, errStat, errMsg )
!..................................................................................................................................

   REAL(DbKi),                   INTENT(IN   )   :: Time        !< Current simulation time in seconds
   TYPE(WD_InputType),           INTENT(IN   )   :: u           !< Inputs at Time
   TYPE(WD_ParameterType),       INTENT(IN   )   :: p           !< Parameters
   TYPE(WD_ContinuousStateType), INTENT(IN   )   :: x           !< Continuous states at Time
   TYPE(WD_DiscreteStateType),   INTENT(IN   )   :: xd          !< Discrete states at Time
   TYPE(WD_ConstraintStateType), INTENT(IN   )   :: z           !< Constraint states at Time (possibly a guess)
   TYPE(WD_OtherStateType),      INTENT(IN   )   :: OtherState  !< Other states at Time
   TYPE(WD_MiscVarType),         INTENT(INOUT)   :: m           !< Misc/optimization variables
   TYPE(WD_ConstraintStateType), INTENT(INOUT)   :: Z_residual  !< Residual of the constraint state equations using
                                                                !!     the input values described above
   INTEGER(IntKi),               INTENT(  OUT)   :: errStat     !< Error status of the operation
   CHARACTER(*),                 INTENT(  OUT)   :: errMsg      !< Error message if errStat /= ErrID_None


   
      ! Local variables   
   integer, parameter                            :: indx = 1  
   integer(intKi)                                :: ErrStat2
   character(ErrMsgLen)                          :: ErrMsg2
   character(*), parameter                       :: RoutineName = 'WD_CalcConstrStateResidual'
   
   
   
   errStat = ErrID_None
   errMsg  = ""

         
   
   
end subroutine WD_CalcConstrStateResidual

subroutine InitStatesWithInputs(numPlanes, numRadii, u, p, xd, m, errStat, errMsg)

   integer(IntKi),               intent(in   )   :: numPlanes
   integer(IntKi),               intent(in   )   :: numRadii
   TYPE(WD_InputType),           intent(in   )   :: u           !< Inputs at Time
   TYPE(WD_ParameterType),       intent(in   )   :: p           !< Parameters
   TYPE(WD_DiscreteStateType),   intent(inout)   :: xd          !< Discrete states at Time
   type(WD_MiscVarType),         intent(inout)   :: m           !< Misc/optimization variables
   INTEGER(IntKi),               intent(  out)   :: errStat     !< Error status of the operation
   CHARACTER(*),                 intent(  out)   :: errMsg      !< Error message if errStat /= ErrID_None
   character(*), parameter                       :: RoutineName = 'InitStatesWithInputs'
   integer(IntKi) :: i
   integer(intKi)                               :: ErrStat2
   character(ErrMsgLen)                         :: ErrMsg2
   real(ReKi)     :: correction(3)
   ! Note, all of these states will have been set to zero in the WD_Init routine
   
     
   ErrStat = ErrID_None
   ErrMsg = ""
   
   
   correction = 0.0_ReKi
   do i = 0, 1
      xd%x_plane     (i)   = u%Vx_rel_disk*real(i,ReKi)*real(p%DT,ReKi)
      xd%YawErr_filt (i)   = u%YawErr
      
      correction = correction + GetYawCorrection(u%YawErr, u%xhat_disk, xd%x_plane(i), p,  errStat2, errMsg2)
      call SetErrStat(errStat2, errMsg2, errStat, errMsg, RoutineName)   
      if (errStat >= AbortErrLev) then
         ! TEST: E3      
         return
      end if
      
      !correction = ( p%C_HWkDfl_x + p%C_HWkDfl_xY*u%YawErr )*xd%x_plane(i) + correctionA
      
      xd%p_plane   (:,i)      = u%p_hub(:) + xd%x_plane(i)*u%xhat_disk(:) + correction
      xd%xhat_plane(:,i)      = u%xhat_disk(:)
      xd%V_plane_filt(:,i)    = u%V_plane(:,i)
      xd%Vx_wind_disk_filt(i) = u%Vx_wind_disk
      xd%TI_amb_filt      (i) = u%TI_amb
      xd%D_rotor_filt     (i) = u%D_rotor
     
      
   end do
   
   xd%Vx_rel_disk_filt     = u%Vx_rel_disk    
   
      ! Initialze Ct_azavg_filt and Vx_wake; Vr_wake is already initialized to zero, so, we don't need to do that here.
   xd%Ct_azavg_filt (:) = u%Ct_azavg(:) 
   
   call NearWakeCorrection( xd%Ct_azavg_filt, xd%Vx_rel_disk_filt, p, m, xd%Vx_wake, errStat, errMsg )
   xd%Vx_wake(:,1) = xd%Vx_wake(:,0)
      
end subroutine InitStatesWithInputs
   
!----------------------------------------------------------------------------------------------------------------------------------
!> This routine validates the inputs from the WakeDynamics input files.
SUBROUTINE ValidateInitInputData( DT, InitInp, InputFileData, errStat, errMsg )
!..................................................................................................................................
      
      ! Passed variables:
   real(DbKi),               intent(in   )  :: DT                                !< requested simulation time step size (s)
   type(WD_InitInputType),   intent(in   )  :: InitInp                           !< Input data for initialization routine
   type(WD_InputFileType),   intent(in)     :: InputFileData                     !< All the data in the WakeDynamics input file
   integer(IntKi),           intent(out)    :: errStat                           !< Error status
   character(*),             intent(out)    :: errMsg                            !< Error message

   
      ! local variables
   integer(IntKi)                           :: k                                 ! Blade number
   integer(IntKi)                           :: j                                 ! node number
   character(*), parameter                  :: RoutineName = 'ValidateInitInputData'
   
   errStat = ErrID_None
   errMsg  = ""
   
   
   ! TODO: Talk to Bonnie about whether we want to convert <= or >= checks to EqualRealNos() .or. >  checks, etc.  GJH
   ! TEST: E13,
   !if (NumBl > MaxBl .or. NumBl < 1) call SetErrStat( ErrID_Fatal, 'Number of blades must be between 1 and '//trim(num2lstr(MaxBl))//'.', ErrSTat, errMsg, RoutineName )
   if (  DT          <=  0.0)  call SetErrStat ( ErrID_Fatal, 'DT must be greater than zero.', errStat, errMsg, RoutineName )  
   if (  InputFileData%NumPlanes   <   2  )  call SetErrStat ( ErrID_Fatal, 'Number of wake planes must be greater than one.', ErrSTat, errMsg, RoutineName )
   if (  InputFileData%NumRadii    <   2  )  call SetErrStat ( ErrID_Fatal, 'Number of radii in the radial finite-difference grid must be greater than one.', ErrSTat, errMsg, RoutineName )
   if (  InputFileData%dr          <=  0.0)  call SetErrStat ( ErrID_Fatal, 'dr must be greater than zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%f_c         <=  0.0)  call SetErrStat ( ErrID_Fatal, 'f_c must be greater than or equal to zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_NearWake  <=  1.0)  call SetErrStat ( ErrID_Fatal, 'C_NearWake must be greater than 1.0.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%k_vAmb      <   0.0)  call SetErrStat ( ErrID_Fatal, 'k_vAmb must be greater than or equal to zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%k_vShr      <   0.0)  call SetErrStat ( ErrID_Fatal, 'k_vShr must be greater than or equal to zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vAmb_DMin <   0.0)  call SetErrStat ( ErrID_Fatal, 'C_vAmb_DMin must be greater than or equal to zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vAmb_DMax <=  InputFileData%C_vAmb_DMin)  call SetErrStat ( ErrID_Fatal, 'C_vAmb_DMax must be greater than C_vAmb_DMin.', errStat, errMsg, RoutineName ) 
   if ( (InputFileData%C_vAmb_FMin <   0.0)  .or. (InputFileData%C_vAmb_FMin > 1.0) ) call SetErrStat ( ErrID_Fatal, 'C_vAmb_FMin must be greater than or equal to zero and less than or equal to 1.0.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vAmb_Exp  <=  0.0)  call SetErrStat ( ErrID_Fatal, 'C_vAmb_Exp must be greater than zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vShr_DMin <   0.0)  call SetErrStat ( ErrID_Fatal, 'C_vShr_DMin must be greater than or equal to zero.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vShr_DMax <=  InputFileData%C_vShr_DMin)  call SetErrStat ( ErrID_Fatal, 'C_vShr_DMax must be greater than C_vShr_DMin.', errStat, errMsg, RoutineName ) 
   if ( (InputFileData%C_vShr_FMin <   0.0)  .or. (InputFileData%C_vShr_FMin > 1.0) ) call SetErrStat ( ErrID_Fatal, 'C_vShr_FMin must be greater than or equal to zero and less than or equal to 1.0.', errStat, errMsg, RoutineName ) 
   if (  InputFileData%C_vShr_Exp  <=  0.0)  call SetErrStat ( ErrID_Fatal, 'C_vShr_Exp must be greater than zero.', errStat, errMsg, RoutineName ) 
   if (.not. ((InputFileData%Mod_WakeDiam == 1) .or. (InputFileData%Mod_WakeDiam == 2) .or. (InputFileData%Mod_WakeDiam == 3) .or. (InputFileData%Mod_WakeDiam == 4)) ) call SetErrStat ( ErrID_Fatal, 'Mod_WakeDiam must be equal to 1, 2, 3, or 4.', errStat, errMsg, RoutineName ) 
   if ( (.not. (InputFileData%Mod_WakeDiam == 1)) .and.( (InputFileData%C_WakeDiam <=   0.0)  .or. (InputFileData%C_WakeDiam >= 1.0)) ) call SetErrStat ( ErrID_Fatal, 'When Mod_WakeDiam is not equal to 1, then C_WakeDiam must be greater than zero and less than 1.0.', errStat, errMsg, RoutineName ) 
   
END SUBROUTINE ValidateInitInputData



!=======================================================================
! Unit Tests
!=======================================================================

subroutine WD_TEST_Init_BadData(errStat, errMsg)

   integer(IntKi),           intent(out)    :: errStat                           !< Error status
   character(*),             intent(out)    :: errMsg                            !< Error message


   type(WD_InitInputType)       :: InitInp       !< Input data for initialization routine
   type(WD_InputType)           :: u             !< An initial guess for the input; input mesh must be defined
   type(WD_ParameterType)       :: p             !< Parameters
   type(WD_ContinuousStateType) :: x             !< Initial continuous states
   type(WD_DiscreteStateType)   :: xd            !< Initial discrete states
   type(WD_ConstraintStateType) :: z             !< Initial guess of the constraint states
   type(WD_OtherStateType)      :: OtherState    !< Initial other states
   type(WD_OutputType)          :: y             !< Initial system outputs (outputs are not calculated;
                                                 !!   only the output mesh is initialized)
   type(WD_MiscVarType)         :: m             !< Initial misc/optimization variables
   real(DbKi)                   :: interval      !< Coupling interval in seconds: the rate that
   
   type(WD_InitOutputType)      :: initOut                         !< Input data for initialization routine
   
                                                                        
   

   
      ! Set up the initialization inputs
   
   interval               = 0.0_DbKi
   InitInp%InputFileData%NumPlanes      = 0
   InitInp%InputFileData%NumRadii       = 0
   InitInp%InputFileData%dr             = 0.0_ReKi
   InitInp%InputFileData%f_c            = 0.0
   InitInp%InputFileData%C_HWkDfl_O     = 0.0
   InitInp%InputFileData%C_HWkDfl_OY    = 0.0
   InitInp%InputFileData%C_HWkDfl_x     = 0.0
   InitInp%InputFileData%C_HWkDfl_xY    = 0.0
   InitInp%InputFileData%C_NearWake     = -1.001
   InitInp%InputFileData%C_vAmb_DMin    = -0.01
   InitInp%InputFileData%C_vAmb_DMax    = -3
   InitInp%InputFileData%C_vAmb_FMin    = 2
   InitInp%InputFileData%C_vAmb_Exp     = 0
   InitInp%InputFileData%C_vShr_DMin    = -.1
   InitInp%InputFileData%C_vShr_DMax    = -3
   InitInp%InputFileData%C_vShr_FMin    = -1
   InitInp%InputFileData%C_vShr_Exp     = -1
   InitInp%InputFileData%k_vAmb         = -2
   InitInp%InputFileData%k_vShr         = -2
   InitInp%InputFileData%Mod_WakeDiam   = 0
   InitInp%InputFileData%C_WakeDiam     = 0
   
   
   call WD_Init( InitInp, u, p, x, xd, z, OtherState, y, m, Interval, InitOut, errStat, errMsg )
   
   return
   
end subroutine WD_TEST_Init_BadData
subroutine WD_TEST_SetGoodInitInpData(interval, InitInp)
   real(DbKi)            , intent(out)       :: interval
   type(WD_InitInputType), intent(out)       :: InitInp       !< Input data for initialization routine

   interval               = 0.1_DbKi
   InitInp%InputFileData%NumPlanes      = 2
   InitInp%InputFileData%NumRadii       = 2
   InitInp%InputFileData%dr             = 0.1_ReKi
   InitInp%InputFileData%f_c            = 0.03333333333333
   InitInp%InputFileData%C_HWkDfl_O     = -2.9
   InitInp%InputFileData%C_HWkDfl_OY    = -.24/D2R
   InitInp%InputFileData%C_HWkDfl_x     = -0.0054
   InitInp%InputFileData%C_HWkDfl_xY    = 0.00039/D2R
   InitInp%InputFileData%C_NearWake     = 2
   InitInp%InputFileData%C_vAmb_DMin    = 0
   InitInp%InputFileData%C_vAmb_DMax    = 2
   InitInp%InputFileData%C_vAmb_FMin    = 0
   InitInp%InputFileData%C_vAmb_Exp     = 1
   InitInp%InputFileData%C_vShr_DMin    = 2
   InitInp%InputFileData%C_vShr_DMax    = 11
   InitInp%InputFileData%C_vShr_FMin    = .035
   InitInp%InputFileData%C_vShr_Exp     = .4
   InitInp%InputFileData%k_vAmb         = .07
   InitInp%InputFileData%k_vShr         = .0178
   InitInp%InputFileData%Mod_WakeDiam   = 1
   InitInp%InputFileData%C_WakeDiam     = .95

end subroutine WD_TEST_SetGoodInitInpData


subroutine WD_TEST_Init_GoodData(errStat, errMsg)

   integer(IntKi),           intent(out)    :: errStat                           !< Error status
   character(*),             intent(out)    :: errMsg                            !< Error message


   type(WD_InitInputType)       :: InitInp       !< Input data for initialization routine
   type(WD_InputType)           :: u             !< An initial guess for the input; input mesh must be defined
   type(WD_ParameterType)       :: p             !< Parameters
   type(WD_ContinuousStateType) :: x             !< Initial continuous states
   type(WD_DiscreteStateType)   :: xd            !< Initial discrete states
   type(WD_ConstraintStateType) :: z             !< Initial guess of the constraint states
   type(WD_OtherStateType)      :: OtherState    !< Initial other states
   type(WD_OutputType)          :: y             !< Initial system outputs (outputs are not calculated;
                                                 !!   only the output mesh is initialized)
   type(WD_MiscVarType)         :: m             !< Initial misc/optimization variables
   real(DbKi)                   :: interval      !< Coupling interval in seconds: the rate that
   
   type(WD_InitOutputType)      :: initOut                         !< Input data for initialization routine
   
                                                                        
   

   
      ! Set up the initialization inputs
   call WD_TEST_SetGoodInitInpData(interval, InitInp)

   call WD_Init( InitInp, u, p, x, xd, z, OtherState, y, m, interval, InitOut, errStat, errMsg )
   
   return
   
end subroutine WD_TEST_Init_GoodData

subroutine WD_TEST_UpdateStates(errStat, errMsg)

   integer(IntKi),           intent(out)    :: errStat                           !< Error status
   character(*),             intent(out)    :: errMsg                            !< Error message


   type(WD_InitInputType)       :: InitInp       !< Input data for initialization routine
   type(WD_InputType)           :: u             !< An initial guess for the input; input mesh must be defined
   type(WD_ParameterType)       :: p             !< Parameters
   type(WD_ContinuousStateType) :: x             !< Initial continuous states
   type(WD_DiscreteStateType)   :: xd            !< Initial discrete states
   type(WD_ConstraintStateType) :: z             !< Initial guess of the constraint states
   type(WD_OtherStateType)      :: OtherState    !< Initial other states
   type(WD_OutputType)          :: y             !< Initial system outputs (outputs are not calculated;
                                                 !!   only the output mesh is initialized)
   type(WD_MiscVarType)         :: m             !< Initial misc/optimization variables
   real(DbKi)                   :: interval      !< Coupling interval in seconds: the rate that
   
   type(WD_InitOutputType)      :: initOut                         !< Input data for initialization routine
   
   integer(IntKi)  :: i,n
   real(DbKi) :: t
   
      ! Set up the initialization inputs
   call WD_TEST_SetGoodInitInpData(interval, InitInp)

   call WD_Init( InitInp, u, p, x, xd, z, OtherState, y, m, interval, InitOut, errStat, errMsg )
   n = 0
      ! Set up the inputs
   u%xhat_disk(1) = 1.0_ReKi
   u%xhat_disk(2) = 0.0_ReKi
   u%xhat_disk(3) = 0.0_ReKi
   u%p_hub(1)     = 10.0_ReKi
   u%p_hub(2)     = 20.0_ReKi
   u%p_hub(3)     = 50.0_ReKi
   do i=0,min(n+1,p%NumPlanes-1)
      u%V_plane(1,i)  = 5 + .5*i
      u%V_plane(2,i)  = 1 + .1*i
      u%V_plane(3,i)  = 1 + .3*i
   end do
   u%Vx_wind_disk = 6.0
   u%TI_amb   = .15    
   u%D_rotor  = 30.0      
   u%Vx_rel_disk = 5.0
   u%YawErr = 5.0*D2R
   do i=0,p%NumRadii-1
      u%Ct_azavg(i) = 0.2 + 0.05*i
   end do
   t = 0.0_DbKi
   call WD_CalcOutput(t, u, p, x, xd, z, OtherState, y, m, errStat, errMsg )
   
   call WD_UpdateStates(t, 0, u, p, x, xd, z, OtherState, m, errStat, errMsg )
   
   t = t + p%DT
   call WD_CalcOutput(t, u, p, x, xd, z, OtherState, y, m, errStat, errMsg )
   
      ! Verify that xd and y are the same
   
   if (errStat == ErrID_None) then
      call WD_UpdateStates(0.0_DbKi, 1, u, p, x, xd, z, OtherState, m, errStat, errMsg )
   end if
   
   return


end subroutine WD_TEST_UpdateStates
end module WakeDynamics
