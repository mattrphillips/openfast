   SUBROUTINE ElementMatrix_Force_New(Nuu0,Nuuu,Nrr0,Nrrr,Nvvv,&
                                      EStif0_GL,EMass0_GL,     &
                                      damp_flag,beta,          &
                                      ngp,node_elem,dof_node,elf)
                           
   !-------------------------------------------------------------------------------
   ! This subroutine total element forces and mass matrices
   !-------------------------------------------------------------------------------

   REAL(ReKi),     INTENT(IN   ):: Nuu0(:) ! Nodal initial position for each element
   REAL(ReKi),     INTENT(IN   ):: Nuuu(:) ! Nodal displacement of Mass 1 for each element
   REAL(ReKi),     INTENT(IN   ):: Nrr0(:) ! Nodal rotation parameters for initial position
   REAL(ReKi),     INTENT(IN   ):: Nrrr(:) ! Nodal rotation parameters for displacement of Mass 1
   REAL(ReKi),     INTENT(IN   ):: Nvvv(:) ! Nodal velocity of Mass 1: m/s for each element
   REAL(ReKi),     INTENT(IN   ):: EStif0_GL(:,:,:) ! Nodal material properties for each element
   REAL(ReKi),     INTENT(IN   ):: EMass0_GL(:,:,:) ! Nodal material properties for each element
   INTEGER(IntKi), INTENT(IN   ):: damp_flag ! Number of Gauss points
   REAL(ReKi),     INTENT(IN   ):: beta(:)
   INTEGER(IntKi), INTENT(IN   ):: ngp ! Number of Gauss points
   INTEGER(IntKi), INTENT(IN   ):: node_elem ! Node per element
   INTEGER(IntKi), INTENT(IN   ):: dof_node ! Degrees of freedom per node
   REAL(ReKi),     INTENT(  OUT):: elf(:)  ! Total element force (Fd, Fc, Fb)

   REAL(ReKi),       ALLOCATABLE:: gp(:) ! Gauss points
   REAL(ReKi),       ALLOCATABLE:: gw(:) ! Gauss point weights
   REAL(ReKi),       ALLOCATABLE:: hhx(:) ! Shape function
   REAL(ReKi),       ALLOCATABLE:: hpx(:) ! Derivative of shape function
   REAL(ReKi),       ALLOCATABLE:: GLL_temp(:) ! Temp Gauss-Lobatto-Legendre points
   REAL(ReKi),       ALLOCATABLE:: w_temp(:) ! Temp GLL weights
   REAL(ReKi)                   :: uu0(6)
   REAL(ReKi)                   :: E10(3)
   REAL(ReKi)                   :: RR0(3,3)
   REAL(ReKi)                   :: kapa(3)
   REAL(ReKi)                   :: E1(3)
   REAL(ReKi)                   :: Stif(6,6)
   REAL(ReKi)                   :: cet
   REAL(ReKi)                   :: uuu(6)
   REAL(ReKi)                   :: uup(3)
   REAL(ReKi)                   :: Jacobian
   REAL(ReKi)                   :: gpr
   REAL(ReKi)                   :: Fc(6)
   REAL(ReKi)                   :: Fd(6)
   REAL(ReKi)                   :: vvv(6)
   REAL(ReKi)                   :: vvp(6)
   REAL(ReKi)                   :: mmm
   REAL(ReKi)                   :: mEta(3)
   REAL(ReKi)                   :: rho(3,3)
   REAL(ReKi)                   :: Fb(6)
   REAL(ReKi)                   :: Sd(6,6)
   REAL(ReKi)                   :: Od(6,6)
   REAL(ReKi)                   :: Pd(6,6)
   REAL(ReKi)                   :: Qd(6,6)
   REAL(ReKi)                   :: betaC(6,6)
   REAL(ReKi)                   :: Gd(6,6)
   REAL(ReKi)                   :: Xd(6,6)
   REAL(ReKi)                   :: Yd(6,6)
   INTEGER(IntKi)               :: igp
   INTEGER(IntKi)               :: i
   INTEGER(IntKi)               :: j
   INTEGER(IntKi)               :: m
   INTEGER(IntKi)               :: n
   INTEGER(IntKi)               :: temp_id1
   INTEGER(IntKi)               :: temp_id2
   INTEGER(IntKi)               :: allo_stat

   ALLOCATE(gp(ngp), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   gp = 0.0D0

   ALLOCATE(gw(ngp), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   gw = 0.0D0

   ALLOCATE(hhx(node_elem), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   hhx = 0.0D0

   ALLOCATE(hpx(node_elem), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   hpx = 0.0D0
   
   ALLOCATE(GLL_temp(node_elem), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   GLL_temp = 0.0D0
   
   ALLOCATE(w_temp(node_elem), STAT = allo_stat)
   IF(allo_stat/=0) GOTO 9999
   w_temp = 0.0D0

   elf(:) = 0.0D0

   CALL BD_gen_gll_LSGL(ngp,GLL_temp,w_temp)
   CALL BldGaussPointWeight(ngp,gp,gw)

   DO igp=1,ngp
       gpr=gp(igp)
       CALL BldComputeJacobianLSGL(gpr,Nuu0,node_elem,dof_node,gp,GLL_temp,ngp,igp,hhx,hpx,Jacobian)
       CALL BldGaussPointDataAt0(hhx,hpx,Nuu0,Nrr0,node_elem,dof_node,uu0,E10)
       Stif(:,:) = 0.0D0
       Stif(1:6,1:6) = EStif0_GL(1:6,1:6,igp)
       CALL BldGaussPointData(hhx,hpx,Nuuu,Nrrr,uu0,E10,node_elem,dof_node,uuu,uup,E1,RR0,kapa,Stif,cet)       
       mmm  = 0.0D0
       mEta = 0.0D0
       rho  = 0.0D0
       mmm          = EMass0_GL(1,1,igp)
       mEta(2)      = -EMass0_GL(1,6,igp)
       mEta(3)      =  EMass0_GL(1,5,igp)
       rho(1:3,1:3) = EMass0_GL(4:6,4:6,igp)
       CALL BldGaussPointDataMass(hhx,hpx,Nvvv,RR0,node_elem,dof_node,vvv,vvp,mmm,mEta,rho)
       CALL ElasticForce(E1,RR0,kapa,Stif,cet,Fc,Fd)
!WRITE(*,*) 'Fc'
!WRITE(*,*) Fc(:)
       IF(damp_flag .EQ. 1) THEN
           CALL DissipativeForce(beta,Stif,vvv,vvp,E1,Fc,Fd,Sd,Od,Pd,Qd,betaC,Gd,Xd,Yd)
       ENDIF
       CALL GyroForce(mEta,rho,uuu,vvv,Fb)

       DO i=1,node_elem
           DO j=1,dof_node
               temp_id1 = (i-1) * dof_node+j
               elf(temp_id1) = elf(temp_id1) + hhx(i)*Fb(j)*Jacobian*gw(igp)
               elf(temp_id1) = elf(temp_id1) + hhx(i)*Fd(j)*Jacobian*gw(igp)
               elf(temp_id1) = elf(temp_id1) + hpx(i)*Fc(j)*Jacobian*gw(igp)
!               elf(temp_id1) = elf(temp_id1) + hhx(i)*Fc(j)*Jacobian*gw(igp)
           ENDDO
       ENDDO
   ENDDO

   DEALLOCATE(gp)
   DEALLOCATE(gw)
   DEALLOCATE(hhx)
   DEALLOCATE(hpx)
   DEALLOCATE(GLL_temp)
   DEALLOCATE(w_temp)

   9999 IF(allo_stat/=0) THEN
            IF(ALLOCATED(gp))  DEALLOCATE(gp)
            IF(ALLOCATED(gw))  DEALLOCATE(gw)
            IF(ALLOCATED(hhx)) DEALLOCATE(hhx)
            IF(ALLOCATED(hpx)) DEALLOCATE(hpx)
            IF(ALLOCATED(GLL_temp)) DEALLOCATE(GLL_temp)
            IF(ALLOCATED(w_temp)) DEALLOCATE(w_temp)
        ENDIF

   END SUBROUTINE ElementMatrix_Force_New
