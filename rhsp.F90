!============================================================================
!  Halla los terminos de la derecha de la ecuacion de Navier-Stokes
!  some terms may seem to be calculated in strange order here and in deriz
!  this is to save memory.


!viscous explicit terms -1/Re*d²()/dx² and  explicit advective terms in X.

! The viscous terms in Y: -1/Re*d²()/dy² are implicit and are apply when we integrate.

! Navier-Stokes equations are marched explictly and implicitly.
!!   equivalences 
!    u      == ut, etc
!    resu   == resut, etc
!    rhsu   == rhsut, etc
!    wki1   == wki1t, etc
!    wkp    == wkf
!    wkpo   == wkfo
!!
!============================================================================

subroutine rhsp(ut,vt,wt,pt,rhsupat,rhsvpat,rhswpat, &
     &          resu,resut,resv,resvt,resw,reswt,      &
     &          rhsut,rhsvt,rhswt,      &
     &          wki1,wki1t,wki2,wki2t,wki3,wki3t,      &
     &          wkp,wkf,wkpo,wkfo,bufuphy,buf_corr,buf_corr2,   &    
     &          dt,m,ical,istep,mpiid,communicator)
  use alloc_dns
  use statistics
  use temporal
  use point
  use ctesp
  use omp_lib

  implicit none
  include 'mpif.h'
  integer,intent(in):: communicator
  
  ! --------------------------- IN/OUT --------------------------!
  real*8, dimension(nx  ,mpu)::wki1,wki3,resu,resw
  real*8, dimension(nx  ,mpv)::wki2,resv

  complex*16,dimension(0:nz2,ny+1,ib:ie)::ut,wt,wki1t,wki3t,rhsut,rhswt,resut,reswt
  complex*16,dimension(0:nz2,ny+1,ib:ie)::rhsupat, rhswpat
  complex*16,dimension(0:nz2,ny  ,ib:ie)::vt,wki2t,rhsvt,resvt,rhsvpat,pt
  
  integer m,mpiid,ical
  !  ------------------------- Workspaces ----------------------!
  real*8 var1,var2,var3,var4,dt,dtloc,uner(15),enerd(15)
  real*8 um,wm,poco,rkk,dt1,dt2,dt3,vmax,maxwk1,maxwk0,wmtmp
  integer i,j,k,l,istep,jv,imaxwk1,kmaxwk1,imaxwk0,kmaxwk0
  integer kk,k2
  !----------------From outside
  complex*16 ,dimension(0:nz2,ny+1)::wkf,wkfo
  complex*16, dimension(0:nz2,ncorr,ib:ie,7,lxcorr):: buf_corr,buf_corr2 !special buffer for correlations 
  real*8,dimension(nz+2,ny+1)      ::wkp,wkpo,bufuphy,bufvphy,bufwphy
  real*8 :: dt1_m,dt2_m,dt3_m,dt4_m,dt4,dt5,dt6,dt7  
  ! --------------------- MPI workspaces -----------------------------!
  integer istat(MPI_STATUS_SIZE),ierr


  ! ===============================================================
  !     interpolate the velocities in P-P-F in 'x' (Everything R*8)
  !     transpose u_>resut and uinterp-> wki  to (zy)         
  ! ===============================================================
  
  call chp2x(resu,ut,rhsut,mpiid,ny+1,communicator) !resu=u in pencils (keep it)
  call chp2x(resv,vt,rhsut,mpiid,ny  ,communicator) !resv=v in pencils (keep it)
  call chp2x(resw,wt,rhsut,mpiid,ny+1,communicator) !resw=w in pencils (keep it)

!---------------------------------------------
  if (dostat) then   
     call interpx_new  (resu,wki1 ,fd_ix,mpu)  !u_x : wki1 [PENCILS]
     ! Written this way, it crashes. You have to reverse this loop and
     ! sometimes, runtimes are not that good
     ! wki1(2:nx,:)=wki1(1:nx-1,:) !Collocate u_x to match with v,w,p
     do i=nx-1,1,-1
        do j=1,mpu
           wki1(i+1,j) = wki1(i,j)
        end do
     end do

     call diffx_inplace(wki1,wki3 ,fd_dx,mpu)  !d(u_x)dx: wki3  [PENCILS]
     call diffx_inplace(resv,rhsvt,fd_dx,mpv)  !dvdx    : rhsvt [PENCILS]
     call diffx_inplace(resw,rhswt,fd_dx,mpu)  !dwdx    : rhswt [PENCILS]   

     call chx2p(wki1, wki1t,rhsut,mpiid,ny+1,communicator) !u_x  [PLANES]
     call chx2p(wki3, wki3t,rhsut,mpiid,ny+1,communicator) !dudx [PLANES]
     call chx2p(rhsvt,rhsvt,rhsut,mpiid,ny  ,communicator) !dvdx [PLANES]
     call chx2p(rhswt,rhswt,rhsut,mpiid,ny+1,communicator) !dwdx [PLANES]  
 
     ical=ical+1
     if (mpiid == 0) write(*,*) "COMPUTE STATISTICS"     
     call statsp(wki1t,vt,wt,pt, &                   !u_x,v,w,p
          &                wki3t,rhsvt,rhswt,&       !dudx,dvdx,dwdx
          &                wkp,wkpo,wki2t,bufuphy,&  !buf1,buf2,buf3,buf4
          &                rhsut,rhswt,wki3t,wki1t,&  !buf5,buf6,buf7,buf8
          &                buf_corr,buf_corr2,rhsut,& !buf_cor,buf_corp,buf_big
          &                wkp,wkpo,bufuphy,&        !bphy1,bphy2,bphy3
          &                mpiid,communicator)
     if (mpiid == 0) write(*,*) "FINISHED WITH STATISTICS"
  endif
!---------------------------------------------

  call interpxx(resu,wki1,inxu,cofiux,inbx,2,mpu,1) !wki1:contains u_x in pencils
  call interpxx(resv,wki2,inxv,cofivx,inbx,1,mpv,0) !wki2:contains v_x in pencils
  call interpxx(resw,wki3,inxv,cofivx,inbx,1,mpu,0) !wki3:contains w_x in pencils 
  ! chx2p works inplace and wki{k} = wki{k}t It contains the velocity field
  ! interpolated in x and aligned in stream normal planes.  
  call chx2p(wki1,wki1t,rhsut,mpiid,ny+1,communicator) !u_x in planes
  call chx2p(wki2,wki2t,rhsut,mpiid,ny,communicator)   !v_x in planes
  call chx2p(wki3,wki3t,rhsut,mpiid,ny+1,communicator) !w_x in planes


  uner= 0d0;um=-1e14; wm=-1e14; vm=-1e14; wmtmp=-1e14;vmtmp=-1e14;  poco  = 1d-7
  if (m==1) call energies(ut,vt,wt,hy,ener,communicator)
  ! ==========================================================
  !    do first all the rhs that need d/dx to free buffers 
  ! ==========================================================
  do i=ib,ie   ! ---- i=1 has to done in this case to diff. in x
     !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(j)
     call fourxz(ut(0:nz2,jbf1:jef1,i),wkp(1:nz+2,jbf1:jef1),1,ny+1,jbf1,jef1)  !  u (phys)
     !$OMP END PARALLEL

     if (setstep) um = max(um,maxval(abs(wkp(1:nz,:))))       !!!  for dt over x                 
     
     !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(j,wmtmp,vmtmp)
     wmtmp=-1e14;vmtmp=-1e14  !firstprivate does not work in BG
    
        do j=jbf1,jef1
           call fourxz(wki1t(0,j,i),wki2r(1:nz+2,ompid),1,1,1,1)         
           wki2r(1:nz,ompid)    = wki2r(1:nz,ompid)**2                  ! u_x**2
           call fourxz(wki1t(0,j,i),wki2r(1:nz+2,ompid),-1,1,1,1)     !<<<<<<<<<<<<<<<<<<<  here !!!!
           call fourxz(wki3t(0,j,i),wki2r(1:nz+2,ompid),1,1,1,1)       
           if (setstep) wmtmp=max(wmtmp,maxval(abs(wki2r(1:nz,ompid))))      !!!  for dt over z
           wki2r(1:nz,ompid)    = wki2r(1:nz,ompid)*wkp(1:nz,j)         ! u*w_x     	
           call fourxz(wki3t(0,j,i),wki2r(1:nz+2,ompid),-1,1,1,1)
        enddo
         if (setstep) then
        !$OMP CRITICAL
        wm=max(wmtmp,wm)
        !$OMP END CRITICAL                
        endif
        !$OMP BARRIER
        
        call interpyy(wkp,wkpo,inyu,cofiuy,inby,ny+1,0,nz+2,nz) ! u interpolated in 'y'      
         !$OMP BARRIER    !extra barrier
        do j=jbf2,jef2                                      
           call fourxz(wki2t(0,j,i),wki2r(1:nz+2,ompid),1,1,1,1)		
           if (setstep) vmtmp(j)=max(vmtmp(j),maxval(abs(wki2r(1:nz,ompid))))   !!!  for dt over y
           wki2r(1:nz,ompid) = wki2r(1:nz,ompid)*wkpo(1:nz,j)           ! v_x*u_y      
           call fourxz(wki2t(0,j,i),wki2r(1:nz+2,ompid),-1,1,1,1)           
        enddo

        if (setstep) then
         !$OMP CRITICAL
         do j=jbf2,jef2
           vm(j)=max(vmtmp(j),vm(j))
         enddo
         !$OMP END CRITICAL          
        endif
        !$OMP BARRIER 

     call differzy(wki2t(0,1,i),wkf,dcyu,dcby,cofcyu,3,1,-1,0,ny+1)
        !$OMP BARRIER    !extra barrier
     do j = jbf1,jef1    ! ny+1 is correct (mark dixit) 
        ! uv/dy + duw/dz for u-equation. 
        rhsut(0:nz2,j,i) = wkf(0:nz2,j)+wki3t(0:nz2,j,i)*kaz(0:nz2)   
     enddo
     !$OMP END PARALLEL
  enddo    !!!  i loop for rhs needing d/dx
 

  ! ============================================================
  !    beginning the part is (x) storage 
  !    finish RHS terms that need x derivatives 
  ! ============================================================
  ! difvisxx(uu,upencil,result) computes de convective+viscous terms in x

  ! rhsu: wki1 contains uu, compute duu/dx. resu contains u in pencils, compute d2(u)/d2x
  call chp2x(wki1,wki1t,rhswt,mpiid,ny+1,communicator)
  call difvisxx(wki1,resu,wki1,dcxu,vixu,dcbx,cofcxu,cofvxu,cofvbx,1,mpu,1,rex) 
  call chx2p(wki1,wki1t,rhswt,mpiid,ny+1,communicator)
  
  ! rhsv: wki2 contains uv, compute duv/dx. resv contains v in pencils, compute d2(v)/d2x
  call chp2x(wki2,wki2t,rhswt,mpiid,ny,communicator)
  call difvisxx(wki2,resv,wki2,dcxv,vixv,dcbx,cofcxv,cofvxv,cofvbx,2,mpv,0,rex)  
  call chx2p(wki2,wki2t,rhswt,mpiid,ny,communicator)

  ! rhsw: wki3 contains uw, compute duw/dx. resw contains w in pencils, compute d2(w)/d2x
  call chp2x(wki3,wki3t,rhswt,mpiid,ny+1,communicator)
  call difvisxx(wki3,resw,wki3,dcxv,vixv,dcbx,cofcxv,cofvxv,cofvbx,2,mpu,0,rex)
  call chx2p(wki3,wki3t,rhswt,mpiid,ny+1,communicator)
  ! =============================================================
  !         (x) storage completed, back to planes
  ! =============================================================

!!!!  complete rhs (zy) ------------ 
  !$OMP PARALLEL WORKSHARE
  rhsut = rhsut + wki1t
  rhsvt =         wki2t
  rhswt =         wki3t  
  !$OMP END PARALLEL WORKSHARE
  if(ie.eq.nx) rhsut(:,:,nx)=wki1t(:,:,nx) !to preserve outflow BC
  ! ================================================================  
  !            wki1, wki2, wki3 are now free 
  !   resu, resv, resw  (in x version) are not used any more, and can be used
  !         to stores u,v,w (in zy) while the veloc. are updated 
  !
  !       update vels. with everything but the nonlinear term 
  ! ================================================================  


  if (setstep) then      !!!!!!!  reduce time step
     dt1=dxmin/max(poco,um)
     dt2=dxmin/max(poco,wm)
     dt3 = minval(dymin/max(poco,vm)) !so conservative.....
      
     dtloc = min(dt1, dt2, dt3, dtret)

     if (mpiid2.eq.0) tm1 = MPI_WTIME()
     call MPI_ALLREDUCE(dtloc,dt,1,MPI_real8,MPI_MIN,MPI_COMM_WORLD,ierr)
     ! if (mpiid2.eq.0) write(*,*) '=====================================dtloc after reduction',dt

#ifdef CFLINFO 
     dt4=dzmin/max(poco,wm)
     dt5=re*cfl*(dxmin*sqrt(3d0)/cfl)**2/6d0
     dt6=minval(re*cfl*(dymin*sqrt(3d0)/cfl)**2/6d0)
     dt7=re*cfl*(dzmin*pi/cfl)**2/pi**2
     !Info about the differents CFLs
     call MPI_ALLREDUCE(dt1,dt1_m,1,MPI_real8,MPI_MIN,communicator,ierr)  
     call MPI_ALLREDUCE(dt2,dt2_m,1,MPI_real8,MPI_MIN,communicator,ierr)  
     call MPI_ALLREDUCE(dt3,dt3_m,1,MPI_real8,MPI_MIN,communicator,ierr)  
     call MPI_ALLREDUCE(dt4,dt4_m,1,MPI_real8,MPI_MIN,communicator,ierr)  
     dtloc=min(dt1_m,dt2_m,dt3_m,dtret)

     if(mpiid.eq.0) then
        write(*,*) '******************************************'
	write(*,'(a15,3f15.8,a8)') 'MAX um,vm,wm:',um,maxval(vm),wm,'    BL-1'	
	write(*,*) '------------------------------------------'
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt1_m: C_u1',dt1,' CFL:',dt/dt1_m*cfl/sqrt(3d0),'    BL-1'	
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt2_m: C_w2',dt2,' CFL:',dt/dt2_m*cfl/sqrt(3d0),'    BL-1'	
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt3_m: C_v ',dt3,' CFL:',dt/dt3_m*cfl/sqrt(3d0),'    BL-1'	
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt4_m: C_w ',dt4,' CFL:',dt/dt4_m*cfl/pi,'    BL-1'	
	write(*,*) '------------------------------------------'
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt5: V_x ',dt5,' CFL:',dt/dt5*cfl/6d0,'    BL-1'	
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt5: V_y ',dt6,' CFL:',dt/dt6*cfl/6d0,'    BL-1'	
	write(*,'(a10,f11.8,a5,f11.8,a8)') 'dt5: V_z ',dt7,' CFL:',dt/dt7*cfl/pi**2,'    BL-1'	
	write(*,*) '------------------------------------------'
	write(*,'(a10,f11.8,a7,f11.8,a7,f11.8,a8)') 'dt_BL1',dtloc,' CFL_1:',dt/dtloc*cfl/sqrt(3d0),' CFL_2:',dt/dtloc*cfl/pi,'    BL-1'	
	write(*,*) '------------------------------------------'
	write(*,'(a10,f11.8,a7,f11.8,a7,f11.8,a8)') 'dt_global',dt,' CFL_1:',cfl/sqrt(3d0),' CFL_2:',cfl/pi,'    BL-1'	
	write(*,*) '******************************************'
      endif
#endif

     if (mpiid2.eq.0) then
        tm2 = MPI_WTIME()
        tmp20 = tmp20 + abs(tm2-tm1)
     endif
     setstep = .FALSE.
  endif
  !  the RK integration constants -------
  var1=dt*(rkcv(m)+rkdv(m))   ! dt*(alpha+beta), for pressure
  var2=dt*rex*rkcv(m)         ! dt/Re*alpha
  var3=dt*rkc(m)              ! dt*gamma
  var4=dt*rkd(m)              ! di*xi 

!!! call chyxz2zyx(p,wki2t,wki1,mpiid,ny)    !! p to (zy) in wki2t

  ! ===================================================================== 
  !     update u with dp/dx, (zy); use wkf as buffer 
  !            save ut,vt,wt  
  !     ACHTUNG:  use wkf as buffer,  resvt cannot b changed anymore !!!!!
  !     ACHTUNG: If you want statistics, use res*t
  !     ACHTUNG: Boundary conditions have to be applied here to uvwt
  !     ACHTUNG: uvwt(1,:), uvw(:,1), uvw(:,end) not be changed after
  !     ACHTUNG: but u(nx,:) has to corrected before pois  
  ! ====================================================================== 

  !$OMP PARALLEL WORKSHARE
  resut=ut
  resvt=vt 
  reswt=wt 
  !$OMP END PARALLEL WORKSHARE

  call genflu(ut,vt,wt,y,re,dt,tiempo,mpiid,m,communicator)
  !Sending Plane to the Big BL (Second BL)
  call MPI_BARRIER(communicator,ierr)
  
  do i=ib0,ie-1
     !$OMP PARALLEL DO DEFAULT(SHARED) PRIVATE(j) SCHEDULE(STATIC)
     do j=2,ny          
        ut(:,j,i)=ut(:,j,i)-var1*idxx*(pt(:,j,i+1)-pt(:,j,i))         
     enddo
  enddo

  ! if (mpiid2.eq.0) tm1 = MPI_WTIME()

  if (mpiid.eq.pnodes-1) then
     call MPI_SEND(pt,(nz2+1)*ny,MPI_COMPLEX16,mpiid-1,0,communicator,istat,ierr)
  elseif (mpiid.eq.0) then
     call MPI_RECV(wkf,(nz2+1)*ny,MPI_COMPLEX16,mpiid+1,0,communicator,istat,ierr)
     !$OMP PARALLEL DO DEFAULT(SHARED) PRIVATE(j) SCHEDULE(STATIC)
     do j=2,ny
        ut(:,j,ie)=ut(:,j,ie)-var1*idxx*(wkf(:,j)-pt(:,j,ie))
     enddo
  else 
     call MPI_SENDRECV(pt,(nz2+1)*ny,MPI_COMPLEX16,mpiid-1,0,&
          &                wkf,(nz2+1)*ny,MPI_COMPLEX16,mpiid+1,0,communicator,istat,ierr)
     !$OMP PARALLEL DO DEFAULT(SHARED) PRIVATE(j) SCHEDULE(STATIC)
     do j=2,ny
        ut(:,j,ie)=ut(:,j,ie)-var1*idxx*(wkf(:,j)-pt(:,j,ie))
     enddo
  endif

  ! if (mpiid==mpiout) write(*,*) '**ut(0,250,xout)** 3',ut(0,250,xout)

  if (mpiid2.eq.0) then
     tm2 = MPI_WTIME()
     tmp16 = tmp16 + abs(tm2-tm1)
  endif
  ! ----------------  u+dp/dx updated,  copy  v, w -------

  do i=ib0,ie
     !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(j,k)
     ! ---  update v,w with pressure gradient
     !$OMP DO SCHEDULE(STATIC)
     do j = 2,ny-1
        vt(:,j,i) = vt(:,j,i)-var1*idyy(j)*(pt(:,j+1,i)-pt(:,j,i))
        wt(:,j,i) = wt(:,j,i)-var1*kaz*pt(:,j,i)
     enddo
     !$OMP END DO NOWAIT
     !$OMP DO SCHEDULE(STATIC)
     do k = 0,nz2
        wt(k,ny,i) = wt(k,ny,i)-var1*kaz(k)*pt(k,ny,i)
     enddo
     !$OMP END PARALLEL
  enddo

  ! ==============================================================
  !      do rest of RHS, and finish updating velocities (including triple products)
  ! ==============================================================

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! 
!!!!!!!!! SI HACEMOS J=2:NY ENTONCES HAY QUE IMPONER BC PARA LOS RHS
!!!!!!!!! SI HACEMOS J=1:NY ENTONCES "NO" HAY QUE IMPONER BC PARA LOS RHS
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!


  do i = ib0,ie  
    if(i.ne.nx) then !this is correct... rhsu(NX)=U_inf*dudx; rhsv(Nx)=U_inf*dvdx (this is done when in pencils)
     !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(j)   
     !$OMP DO SCHEDULE(STATIC)
     do j = 2,ny-1   !----- Dissipative terms in z; kvis(:)=rex*kaz2(:)
        rhsut(:,j,i) = rhsut(:,j,i)-resut(:,j,i)*kvis
        rhswt(:,j,i) = rhswt(:,j,i)-reswt(:,j,i)*kvis 
        rhsvt(:,j,i) = rhsvt(:,j,i)-resvt(:,j,i)*kvis     
     enddo
     !$OMP END DO NOWAIT
     !$OMP DO SCHEDULE(STATIC)
     do k=0,nz2
        rhsut(k,ny,i) = rhsut(k,ny,i)-resut(k,ny,i)*kvis(k)
        rhswt(k,ny,i) = rhswt(k,ny,i)-reswt(k,ny,i)*kvis(k)
     enddo

     call interpyy(reswt(0,1,i),wkf,inyu,cofiuy,inby,ny+1,0,nz1,nz1)    
     !$OMP BARRIER    !extra barrier     
     call fourxz(wkf(0:nz2,jbf1:jef1),wkpo(1:nz+2,jbf1:jef1),1,ny+1,jbf1,jef1) ! wkpo = w interp in y     
     !$OMP BARRIER    !extra barrier     

     do j = jbf2,jef2                         !!!  what happens to ny+1 ??               
        call fourxz(resvt(0,j,i),wki2r(1:nz+2,ompid),1,1,1,1) 
        wkp(1:nz,j) = wki2r(1:nz,ompid)*wkpo(1:nz,j)        !vw at v locations           
     enddo
     !$OMP BARRIER

     call fourxz(wkfo(0:nz2,jbf1:jef1),wkp(1:nz+2,jbf1:jef1),-1,ny+1,jbf1,jef1)    ! wkfo = vw at v locations
     !$OMP BARRIER
     ! dvw/dz for v-equation     
     do j = jbf2,jef2                         	 
        rhsvt(0:nz2,j,i) = rhsvt(0:nz2,j,i)+wkfo(0:nz2,j)*kaz(0:nz2)	  
     enddo
     ! dvw/dy for w-equation    
     call differzy(wkfo,wkf,dcyu,dcby,cofcyu,3,1,-1,0,ny+1)    
     !$OMP BARRIER    !extra barrier          
     do j = jbf1,jef1            
        rhswt(0:nz2,j,i) = rhswt(0:nz2,j,i) + wkf(0:nz2,j)      
     enddo
     !$OMP BARRIER

     ! --------  dvv/dy for v-equation   
     call interpyy(resvt(0,1,i),wkf,inyv,cofivy,inby,ny,1,nz1,nz1)
     !$OMP BARRIER    !extra barrier
     call fourxz(wkf(0:nz2,jbf2:jef2),wkpo(1:nz+2,jbf2:jef2),1,ny,jbf2,jef2)     !!!  v (phys)
     !$OMP BARRIER 
    
    
     do j=jbf2,jef2
        wkp(1:nz,j) = wkpo(1:nz,j)**2    ! multiplica para v: vv    
     enddo
     !$OMP BARRIER

     call fourxz(wkfo(0:nz2,jbf2:jef2),wkp(1:nz+2,jbf2:jef2),-1,ny,jbf2,jef2)
     !$OMP BARRIER
     call differzy(wkfo,wkf,dcyv,dcby,cofcyv,1,1,0,1,ny)
     !$OMP BARRIER    !extra barrier    
     do j=jbf2,jef2
        rhsvt(0:nz2,j,i) = rhsvt(0:nz2,j,i) + wkf(0:nz2,j)	               
        ! ------- dww/dz for w-equation   (ny+1 is superseeded by bc)             
        call fourxz(reswt(0,j,i),wki2r(1:nz+2,ompid),1,1,1,1)       
        wki2r(1:nz,ompid) = wki2r(1:nz,ompid)**2 
        call fourxz(wkf(0,j),wki2r(1:nz+2,ompid),-1,1,1,1)                              
        rhswt(0:nz2,j,i) = rhswt(0:nz2,j,i)+wkf(0:nz2,j)*kaz(0:nz2)
     enddo
     !$OMP END PARALLEL    
   endif
  enddo     !!! loop on i
  ! ======  ACHTUNG!!! impose & preserve viscous boundary conditions  ========

  call boun(ut,vt,wt)

  !$OMP PARALLEL WORKSHARE
  rhsut(:,:,ib:ib0-1) = 0d0 
  rhsvt(:,:,ib:ib0-1) = 0d0 
  rhswt(:,:,ib:ib0-1) = 0d0
  
  rhsvt(:,1,:)= 0d0
  rhsvt(:,ny  ,:)= 0d0
  !$OMP END PARALLEL WORKSHARE


  !$OMP PARALLEL DO DEFAULT(SHARED) PRIVATE(kk,i,k,k2) SCHEDULE(STATIC)
  do kk=0,nz2,blockl
    k2=min(nz2,kk+blockl-1)
    do i=ib,ie
       do k=kk,k2
	rhsut(k,1,i)= -1d0/inby(2,1)*(inby(2,2)*rhsut(k,2,i)+inby(2,3)*rhsut(k,3,i)+inby(2,4)*rhsut(k,4,i))   
	rhswt(k,1,i)= -1d0/inby(2,1)*(inby(2,2)*rhswt(k,2,i)+inby(2,3)*rhswt(k,3,i)+inby(2,4)*rhswt(k,4,i))

	rhsut(k,ny+1,i)=0d0 
	rhswt(k,ny+1,i)=0d0
      enddo
    enddo
  enddo
  
  ! -- final velocity updates (var4(m=1)=0)     
    do i=ib0,ie
      if(i.eq.nx) var2=0d0 !Viscous terms equal 0 in the last plane

      !$OMP PARALLEL DEFAULT(SHARED) PRIVATE(j) 
      call vistyy(resvt(0,1,i),wkf,viyv,cofvyv,cofvby,ny)
      !$OMP DO SCHEDULE(STATIC)
      do j=1,ny   !in the implicit terms, always from 1:jee-1=1:ny at least!!	
	wki2t(:,j,i) =  vt(:,j,i)-(var3*rhsvt(:,j,i)+var2*wkf(:,j)+var4*rhsvpat(:,j,i))  		
      enddo 

      call vistyy(resut(0,1,i),wkf,viyu,cofvyu,cofvby,ny+1)                         
      !$OMP DO SCHEDULE(STATIC)
      do j=1,ny+1   !in the implicit terms, always from 1:jee-1=1:ny at least!!
	wki1t(:,j,i) =   ut(:,j,i) -(var3*rhsut(:,j,i)+var2*wkf(:,j)+var4*rhsupat(:,j,i)) 		            
      enddo 
 
      call vistyy(reswt(0,1,i),wkf,viyu,cofvyu,cofvby,ny+1)
      !$OMP DO SCHEDULE(STATIC)
      do j=1,ny+1   !in the implicit terms, always from 1:jee-1=1:ny at least!!	
	wki3t(:,j,i) =   wt(:,j,i) -(var3*rhswt(:,j,i)+var2*wkf(:,j)+var4*rhswpat(:,j,i)) 	            
      enddo     
      !$OMP END PARALLEL                          
    enddo 
  !$OMP PARALLEL WORKSHARE  
  rhsupat = rhsut
  rhsvpat = rhsvt
  rhswpat = rhswt
  !$OMP END PARALLEL WORKSHARE


  ! -----  implicit (y) viscous steps 
  rkk =rex*dt*rkdv(m)
  do i=ib0,ie
     call implzy(ut(0,1,i),wki1t(0,1,i),vyui,cofvyu,ny+1,rkk)
     call implzy(vt(0,1,i),wki2t(0,1,i),vyvi,cofvyv,ny  ,rkk)
     call implzy(wt(0,1,i),wki3t(0,1,i),vyui,cofvyu,ny+1,rkk)
  enddo

  ! if (mpiid==mpiout) write(*,*) '**ut(0,250,xout)** 4',ut(0,250,xout)
  ener(13:15)=0
  dostat  = .FALSE.  
end subroutine rhsp


! ===============================================================
subroutine energies(ut,vt,wt,hy,ener,communicator)
  use ctesp
  use point
  implicit none
  include 'mpif.h'
  integer,intent(in)::communicator
  complex*16 ut(0:nz2,ny+1,ib:ie),vt(0:nz2,ny,ib:ie),wt(0:nz2,ny+1,ib:ie)
  real*8     hy(0:ny),uner(15),ener(15)
  integer i,ierr

  uner=0d0
  do i=ib,ie
     call ministats(ut(0,1,i),vt(0,1,i),wt(0,1,i),uner,hy,i) 
  enddo
  call MPI_ALLREDUCE(uner,ener,15,MPI_real8,MPI_sum,communicator,ierr)

end subroutine energies
