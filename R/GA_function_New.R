postGWAS <- function(Y,SNPs,significant,number_cores = 1,principal_components,maxiterations = 100,runs_til_stop = 10,kinship = FALSE,info = FALSE){

  if(sum(apply(SNPs,2,is.numeric)) != ncol(SNPs)){
    stop("Not every column of SNPs is numeric")
  }
  if(sum(apply(SNPs,2,sum) > nrow(SNPs))){
    stop("Some values of the SNP matrix are not 0 or 1")
  }
  if(!(is.numeric(Y))){
    stop("Y is not a numeric vector")
  }
  if(!is.logical(kinship)){
    if(!((nrow(kinship) == nrow(SNPs)) & (ncol(kinship) == nrow(SNPs)))){
      stop("kinship does not have the dimensions nrow(SNPs) x nrow(SNPs)")
    }
  }else{
    if(kinship == TRUE){
      stop("kinship can only take on the values of FALSE or a matrix nrow(SNPs) x nrow(SNPs)")
    }
  }
  if(!is.logical(principal_components)){
    if(!(nrow(principal_components) == nrow(SNPs))){
      stop("principal_components does not have the the same number of rows as SNPs")
    }
    if(sum(apply(principal_components,2,is.numeric)) != ncol(principal_components)){
      stop("Not every column of principal_components is numeric")
    }
  }else{
    if(principal_components == TRUE){
      stop("principal_components can only take on the values of FALSE or a matrix with the same number of rows as SNPs")
    }
  }
  if(!(is.numeric(significant))){
    stop("significant is not a numeric vector")
  }
  if(!is.logical(info)){
    if(!((nrow(info) == 2) & (ncol(info) == ncol(SNPs)))){
      stop("info does not have the dimensions 2 x ncol(SNPs)")
    }
  }else{
    if(info == TRUE){
      stop("info can only take on the values of FALSE or a matrix 2 x ncol(SNPs)")
    }
  }
  if(!is.numeric(number_cores)){
    stop("number_cores is not numeric")
  }
  if(!is.numeric(maxiterations)){
    stop("maxiterations needs to be numeric")
  }
  if(!is.numeric(runs_til_stop)){
    stop("runs_til_stop needs to be numeric")
  }

  if(sum(significant) > 11){
    if(is.logical(principal_components)){
      results <- ga_modelselection_nopc(Y = Y,SNPs,significant = significant,number_cores = number_cores,maxiterations = maxiterations,runs_til_stop = runs_til_stop,kinship = kinship)
    }else{
      results <- ga_modelselection_pcs(Y = Y,SNPs,significant = significant,number_cores = number_cores,principal_components = principal_components,maxiterations = maxiterations,runs_til_stop = runs_til_stop,kinship = kinship)
    }
    if(is.logical(info)){
      return(results)
    }else{
      info <- info[,significant == 1]
      info <- paste0(info[1,],"-",info[2,])
      colnames(results$Solution) <- info
      return(results)
    }
  }else{
    if(is.logical(principal_components)){
      requireNamespace("GA")
      requireNamespace("parallel")
      requireNamespace("doParallel")
      requireNamespace("Matrix")
      requireNamespace("caret")
      requireNamespace("memoise")

      original_n <- ncol(SNPs)
      Xy <- cbind(Y,SNPs)
      y1 <- c("y",paste0("SNP",1:ncol(SNPs)))
      colnames(Xy) <- y1
      y1 <- y1[y1 %in% paste0("SNP",1:ncol(SNPs))]
      X <- as.matrix(Xy[,y1])
      Y <- matrix(Xy[,1],ncol = 1)
      rm(Xy)

      P <- 2

      y1 <- colnames(X)[significant == 1]

      if(is.logical(kinship)){
        #SLR
        nX <- nrow(X)
        X <- X[,significant == 1]

        fitness_sub <- function(string) {
          inc <- which(string == 1)
          SNPdata_list_sub <- cbind(1,X[,inc])

          if(Matrix::rankMatrix(SNPdata_list_sub)[1] < ncol(SNPdata_list_sub)){
            dropped_cols <- caret::findLinearCombos(SNPdata_list_sub)$remove
            SNPdata_list_sub <- SNPdata_list_sub[,-dropped_cols]
            print(paste0("Dropped Columns: ",dropped_cols))
          }
          return((-1)*optim_llik_SLR_BIC(SNPdata_list_sub,Y))
        }

        n <- ncol(X)
        l <- rep(list(0:1), n)
        l <- expand.grid(l)
        colnames(l) <- y1
        ol <- as.matrix(l)
        l <- split(l,1:nrow(l))

        if(.Platform$OS.type == "unix"){
          l <- unlist(mclapply(l,fitness_sub,mc.cores = number_cores))
        } else{
          cl <- makeCluster(number_cores)
          clusterExport(cl,c("l","fitness_sub","X","optim_llik_SLR_BIC","rankMatrix","findLinearCombos","Y"),envir=environment())
          l <- unlist(parLapply(cl,l,fitness_sub))
          stopCluster(cl)
        }

        dat <- cbind(ol,l)
        dat[,ncol(dat)] <- (-1)*dat[,ncol(dat)]
        dat <- cbind(dat,(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))/(sum(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))))

        dat <- dat[order(dat[,ncol(dat)],decreasing = FALSE),]
        anstf <- cumsum(dat[,ncol(dat)]) > .05
        ans <- matrix(dat[anstf,1:(ncol(dat) - 2)],ncol = (ncol(dat) - 2),nrow = sum(anstf))
        colnames(ans) <- y1

        vec1 <- matrix(0,nrow = nrow(dat),ncol = nrow(ans))
        for(i in 1:nrow(dat)){
          for(j in 1:nrow(ans)){
            vec1[i,j] <- sum(dat[i,1:(ncol(dat) - 2)] == ans[j,])
          }
        }
        vec <- vector()
        for(i in 1:nrow(ans)){
          vec[i] <- paste0("Model ",i,": y ~ ",paste(names(which(ans[i,] == 1)),collapse = " + ")," Posterior Prob. of ",round(dat[which(vec1[,i] == (ncol(dat) - 2)),ncol(dat)],digits = 4))
        }
        results <- list(Models = vec,Solution = ans)
        if(is.logical(info)){
          return(results)
        }else{
          info <- info[,significant == 1]
          info <- paste0(info[1,],"-",info[2,])
          colnames(results$Solution) <- info
          return(results)
        }

      }else{
        #SLR w Kinship
        nX <- nrow(X)
        X <- X[,significant == 1]

        spec.decomp <- eigen(kinship,symmetric = TRUE)
        Q <- spec.decomp$vectors
        Qt <- t(Q)
        D <- diag(spec.decomp$values,nrow = nX,ncol = nX)
        rm(spec.decomp)

        intercept <- matrix(1,nrow = nX,ncol = 1)
        intercept <- do.call(eigenMapMatMult2,list(Qt,intercept))
        Y <- do.call(eigenMapMatMult2,list(Qt,Y)); X <- do.call(eigenMapMatMult2,list(Qt,X))
        rm(Qt);rm(Q)

        fitness_sub <- function(string){
          X_sub <- cbind(intercept,X[,string == 1])
          if(Matrix::rankMatrix(X_sub)[1] < ncol(X_sub)){
            dropped_cols <- caret::findLinearCombos(X_sub)$remove
            X_sub <- X_sub[,-dropped_cols]
            print(paste0("Dropped Columns: ",dropped_cols))
          }
          return((-1)*optim_llik_RE_BIC(X_sub,Y,D))
        }
        n <- ncol(X)
        l <- rep(list(0:1), n)
        l <- expand.grid(l)
        colnames(l) <- y1
        ol <- as.matrix(l)
        l <- split(l,1:nrow(l))

        if(.Platform$OS.type == "unix"){
          l <- unlist(mclapply(l,fitness_sub,mc.cores = number_cores))
        } else{
          cl <- makeCluster(number_cores)
          clusterExport(cl,c("l","fitness_sub","X","D","optim_llik_RE_BIC","rankMatrix","findLinearCombos","Y","intercept"),envir=environment())
          l <- unlist(parLapply(cl,l,fitness_sub))
          stopCluster(cl)
        }

        dat <- cbind(ol,l)
        dat[,ncol(dat)] <- (-1)*dat[,ncol(dat)]
        dat <- cbind(dat,(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))/(sum(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))))

        dat <- dat[order(dat[,ncol(dat)],decreasing = FALSE),]
        anstf <- cumsum(dat[,ncol(dat)]) > .05
        ans <- matrix(dat[anstf,1:(ncol(dat) - 2)],ncol = (ncol(dat) - 2),nrow = sum(anstf))
        colnames(ans) <- y1

        vec1 <- matrix(0,nrow = nrow(dat),ncol = nrow(ans))
        for(i in 1:nrow(dat)){
          for(j in 1:nrow(ans)){
            vec1[i,j] <- sum(dat[i,1:(ncol(dat) - 2)] == ans[j,])
          }
        }
        vec <- vector()
        for(i in 1:nrow(ans)){
          vec[i] <- paste0("Model ",i,": y ~ ",paste(names(which(ans[i,] == 1)),collapse = " + ")," Posterior Prob. of ",round(dat[which(vec1[,i] == (ncol(dat) - 2)),ncol(dat)],digits = 4))
        }
        results <- list(Models = vec,Solution = ans)
        if(is.logical(info)){
          return(results)
        }else{
          info <- info[,significant == 1]
          info <- paste0(info[1,],"-",info[2,])
          colnames(results$Solution) <- info
          return(results)
        }
      }

    }else{
      requireNamespace("GA")
      requireNamespace("parallel")
      requireNamespace("doParallel")
      requireNamespace("Matrix")
      requireNamespace("caret")
      requireNamespace("memoise")

      original_n <- ncol(SNPs)
      Xy <- cbind(Y,SNPs,principal_components)
      y1 <- c("y",paste0("SNP",1:ncol(SNPs)),paste0("PC",1:ncol(principal_components)))
      colnames(Xy) <- y1
      y1 <- y1[y1 %in% paste0("SNP",1:ncol(SNPs))]
      X <- as.matrix(Xy[,y1])
      Y <- matrix(Xy[,1],ncol = 1)
      principal_components <- as.matrix(Xy[,colnames(Xy)%in%paste0("PC",1:ncol(principal_components))])
      rm(Xy)

      P <- 2 + ncol(principal_components)

      y1 <- colnames(X)[significant == 1]

      if(is.logical(kinship)){
        #SLR
        nX <- nrow(X)
        X <- X[,significant == 1]

        fitness_sub <- function(string) {
          inc <- which(string == 1)
          SNPdata_list_sub <- cbind(1,X[,inc],principal_components)

          if(Matrix::rankMatrix(SNPdata_list_sub)[1] < ncol(SNPdata_list_sub)){
            dropped_cols <- caret::findLinearCombos(SNPdata_list_sub)$remove
            SNPdata_list_sub <- SNPdata_list_sub[,-dropped_cols]
            print(paste0("Dropped Columns: ",dropped_cols))
          }
          return((-1)*optim_llik_SLR_BIC(SNPdata_list_sub,Y))
        }

        n <- ncol(X)
        l <- rep(list(0:1), n)
        l <- expand.grid(l)
        colnames(l) <- y1
        ol <- as.matrix(l)
        l <- split(l,1:nrow(l))

        if(.Platform$OS.type == "unix"){
          l <- unlist(mclapply(l,fitness_sub,mc.cores = number_cores))
        } else{
          cl <- makeCluster(number_cores)
          clusterExport(cl,c("l","fitness_sub","X","optim_llik_SLR_BIC","rankMatrix","findLinearCombos","Y","principal_components"),envir=environment())
          l <- unlist(parLapply(cl,l,fitness_sub))
          stopCluster(cl)
        }

        dat <- cbind(ol,l)
        dat[,ncol(dat)] <- (-1)*dat[,ncol(dat)]
        dat <- cbind(dat,(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))/(sum(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))))

        dat <- dat[order(dat[,ncol(dat)],decreasing = FALSE),]
        anstf <- cumsum(dat[,ncol(dat)]) > .05
        ans <- matrix(dat[anstf,1:(ncol(dat) - 2)],ncol = (ncol(dat) - 2),nrow = sum(anstf))
        colnames(ans) <- y1

        vec1 <- matrix(0,nrow = nrow(dat),ncol = nrow(ans))
        for(i in 1:nrow(dat)){
          for(j in 1:nrow(ans)){
            vec1[i,j] <- sum(dat[i,1:(ncol(dat) - 2)] == ans[j,])
          }
        }
        vec <- vector()
        for(i in 1:nrow(ans)){
          vec[i] <- paste0("Model ",i,": y ~ ",paste(names(which(ans[i,] == 1)),collapse = " + ")," Posterior Prob. of ",round(dat[which(vec1[,i] == (ncol(dat) - 2)),ncol(dat)],digits = 4))
        }
        results <- list(Models = vec,Solution = ans)
        if(is.logical(info)){
          return(results)
        }else{
          info <- info[,significant == 1]
          info <- paste0(info[1,],"-",info[2,])
          colnames(results$Solution) <- info
          return(results)
        }
      }else{
        #SLR w Kinship
        nX <- nrow(X)
        X <- X[,significant == 1]

        spec.decomp <- eigen(kinship,symmetric = TRUE)
        Q <- spec.decomp$vectors
        Qt <- t(Q)
        D <- diag(spec.decomp$values,nrow = nX,ncol = nX)
        rm(spec.decomp)

        intercept <- matrix(1,nrow = nX,ncol = 1)
        intercept <- do.call(eigenMapMatMult2,list(Qt,intercept))
        Y <- do.call(eigenMapMatMult2,list(Qt,Y)); X <- do.call(eigenMapMatMult2,list(Qt,X));principal_components <- do.call(eigenMapMatMult2,list(Qt,principal_components))
        rm(Qt);rm(Q)

        fitness_sub <- function(string){
          X_sub <- cbind(intercept,X[,string == 1],principal_components)
          if(Matrix::rankMatrix(X_sub)[1] < ncol(X_sub)){
            dropped_cols <- caret::findLinearCombos(X_sub)$remove
            X_sub <- X_sub[,-dropped_cols]
            print(paste0("Dropped Columns: ",dropped_cols))
          }
          return((-1)*optim_llik_RE_BIC(X_sub,Y,D))
        }
        n <- ncol(X)
        l <- rep(list(0:1), n)
        l <- expand.grid(l)
        colnames(l) <- y1
        ol <- as.matrix(l)
        l <- split(l,1:nrow(l))

        if(.Platform$OS.type == "unix"){
          l <- unlist(mclapply(l,fitness_sub,mc.cores = number_cores))
        } else{
          cl <- makeCluster(number_cores)
          clusterExport(cl,c("l","fitness_sub","X","D","optim_llik_RE_BIC","rankMatrix","findLinearCombos","Y","principal_components"),envir=environment())
          l <- unlist(parLapply(cl,l,fitness_sub))
          stopCluster(cl)
        }

        dat <- cbind(ol,l)
        dat[,ncol(dat)] <- (-1)*dat[,ncol(dat)]
        dat <- cbind(dat,(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))/(sum(exp(-.5 * (dat[,ncol(dat)] - max(dat[,ncol(dat)]))))))

        dat <- dat[order(dat[,ncol(dat)],decreasing = FALSE),]
        anstf <- cumsum(dat[,ncol(dat)]) > .05
        ans <- matrix(dat[anstf,1:(ncol(dat) - 2)],ncol = (ncol(dat) - 2),nrow = sum(anstf))
        colnames(ans) <- y1

        vec1 <- matrix(0,nrow = nrow(dat),ncol = nrow(ans))
        for(i in 1:nrow(dat)){
          for(j in 1:nrow(ans)){
            vec1[i,j] <- sum(dat[i,1:(ncol(dat) - 2)] == ans[j,])
          }
        }
        vec <- vector()
        for(i in 1:nrow(ans)){
          vec[i] <- paste0("Model ",i,": y ~ ",paste(names(which(ans[i,] == 1)),collapse = " + ")," Posterior Prob. of ",round(dat[which(vec1[,i] == (ncol(dat) - 2)),ncol(dat)],digits = 4))
        }
        results <- list(Models = vec,Solution = ans)
        if(is.logical(info)){
          return(results)
        }else{
          info <- info[,significant == 1]
          info <- paste0(info[1,],"-",info[2,])
          colnames(results$Solution) <- info
          return(results)
        }
      }

    }
  }
}
